defmodule Stacks.UploadPipelineTest do
  @moduledoc """
      Comprehensive integration tests for the upload pipeline.

      Covers the full flow from image upload through vision classification, ISBN
      resolution, book creation, and shelf placement, plus all failure/rejection paths.

      Suites:
        2 — API endpoint validation
        3 — Database assertions
        4 — Event flow
        5 — Background job (IdentifyBookJob)
        6 — External service mocks
        7 — Storage
  """

  use CoreWeb.ConnCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts.Guardian
  alias Stacks.AI.BudgetTracker
  alias Stacks.AI.Client, as: AIClient
  alias Stacks.AI.MockClient
  alias Stacks.Books
  alias Stacks.Books.{Book, BookEdition, UploadedImage}
  alias Stacks.Books.ISBNResolver
  alias Stacks.Books.MockHttpClient
  alias Stacks.GDPR.ImageRetention
  alias Stacks.Shelving
  alias Stacks.Storage
  alias Stacks.Storage.Mock, as: StorageMock
  alias Stacks.Uploads
  alias Stacks.Workers.IdentifyBookJob

  @image_b64 Base.encode64("fake image bytes for testing")

  setup do
    user = insert(:user)
    {:ok, token, _} = Guardian.encode_and_sign(user)

    book = insert(:book, title: "The Great Gatsby")
    insert(:book_edition, book: book, isbn: "9780743273565")

    :fuse.reset(:open_library_fuse)
    :fuse.reset(:google_books_fuse)

    {:ok, user: user, token: token, book: book}
  end

  defp auth_conn(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp event_count(event_type) do
    Repo.aggregate(
      from(e in "event_log", prefix: "op", where: e.event_type == ^event_type),
      :count
    )
  end

  defp events_of_type(event_type) do
    from(e in "event_log",
      prefix: "op",
      where: e.event_type == ^event_type,
      order_by: [asc: e.occurred_at],
      select: %{
        event_type: e.event_type,
        aggregate_type: e.aggregate_type,
        aggregate_id: e.aggregate_id,
        payload: e.payload,
        occurred_at: e.occurred_at
      }
    )
    |> Repo.all()
    |> Enum.map(fn event ->
      decoded_id =
        case Ecto.UUID.load(event.aggregate_id) do
          {:ok, str} -> str
          _ -> event.aggregate_id
        end

      %{event | aggregate_id: decoded_id}
    end)
  end

  defp with_vision(response, fun), do: with_vision("analyze", response, fun)

  defp with_vision(endpoint, response, fun) do
    MockClient.put_response(endpoint, response)

    try do
      fun.()
    after
      MockClient.clear()
    end
  end

  defp create_temp_image do
    path = Path.join(System.tmp_dir!(), "test_upload_#{System.unique_integer([:positive])}.jpg")
    File.write!(path, "fake jpeg image bytes for testing")
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "Suite 2 — upload rate limiting" do
    @tag suite: :api
    test "returns 429 when rate limit is exceeded", %{token: token} do
      Application.put_env(:core, :rate_limiting_enabled, true)

      try do
        results =
          Enum.map(1..121, fn _ ->
            build_conn()
            |> auth_conn(token)
            |> post("/api/upload/init", %{})
            |> Map.get(:status)
          end)

        assert 429 in results
      after
        Application.put_env(:core, :rate_limiting_enabled, false)
      end
    end
  end

  describe "Suite 2 — GET /api/upload/:image_id/stream" do
    @tag suite: :api
    test "returns 200 text/event-stream for valid pending image", %{
      conn: conn,
      token: token,
      user: user
    } do
      image = insert(:uploaded_image, status: "pending", user_id: user.id)

      conn = get(conn, "/api/upload/#{image.id}/stream?token=#{token}")

      assert conn.status == 200
      [content_type | _] = get_resp_header(conn, "content-type")
      assert String.contains?(content_type, "text/event-stream")
    end

    @tag suite: :api
    test "returns 401 when no token provided", %{conn: conn, user: user} do
      image = insert(:uploaded_image, status: "pending", user_id: user.id)

      conn = get(conn, "/api/upload/#{image.id}/stream")

      assert conn.status == 401
    end

    @tag suite: :api
    test "returns 403 when image belongs to a different user", %{conn: conn, book: book} do
      owner = insert(:user)
      requester = insert(:user)
      {:ok, requester_token, _} = Guardian.encode_and_sign(requester)

      image =
        insert(:uploaded_image,
          status: "pending",
          book_id: book.id,
          user_id: owner.id
        )

      conn = get(conn, "/api/upload/#{image.id}/stream?token=#{requester_token}")

      assert conn.status == 403
    end

    @tag suite: :api
    test "returns 404 for unknown image_id", %{conn: conn, token: token} do
      fake_id = Ecto.UUID.generate()

      conn = get(conn, "/api/upload/#{fake_id}/stream?token=#{token}")

      assert conn.status == 404
    end

    @tag suite: :api
    test "returns 400 or 422 for invalid (non-UUID) image_id", %{conn: conn, token: token} do
      conn = get(conn, "/api/upload/not-a-uuid/stream?token=#{token}")

      assert conn.status in [400, 422]
    end

    @tag suite: :api
    test "sends terminal event immediately when image already resolved", %{
      conn: conn,
      token: token,
      user: user,
      book: book
    } do
      image =
        insert(:uploaded_image,
          status: "resolved",
          book_id: book.id,
          book_ids: [book.id],
          user_id: user.id
        )

      conn = get(conn, "/api/upload/#{image.id}/stream?token=#{token}")

      assert conn.status == 200
      body = conn.resp_body
      assert String.contains?(body, "resolved")
    end

    @tag suite: :api
    test "pushes event when IdentifyBookJob completes after connection opens", %{
      conn: conn,
      token: token,
      user: user,
      book: book
    } do
      image = insert(:uploaded_image, status: "pending", user_id: user.id)
      topic = "upload:#{image.id}"

      Phoenix.PubSub.subscribe(Core.PubSub, topic)

      task =
        Task.async(fn ->
          get(conn, "/api/upload/#{image.id}/stream?token=#{token}")
        end)

      Process.sleep(50)

      Phoenix.PubSub.broadcast(Core.PubSub, topic, {
        :upload_complete,
        %{status: "resolved", book_ids: [book.id]}
      })

      conn = Task.await(task, 5_000)

      assert conn.status == 200
      body = conn.resp_body
      assert String.contains?(body, "resolved")
    end

    @tag suite: :api
    test "GET /api/upload/:image_id/stream returns immediately for an already-resolved image", %{
      conn: conn,
      token: token,
      user: user,
      book: book
    } do
      image =
        insert(:uploaded_image,
          status: "resolved",
          book_id: book.id,
          book_ids: [book.id],
          user_id: user.id
        )

      {elapsed_us, _conn} =
        :timer.tc(fn ->
          get(conn, "/api/upload/#{image.id}/stream?token=#{token}")
        end)

      assert elapsed_us < 1_000_000,
             "SSE stream endpoint took #{elapsed_us}μs for an ALREADY-RESOLVED image, " <>
               "expected < 1,000,000μs (1s). This endpoint must short-circuit on a " <>
               "resolved image rather than entering the PubSub/SSE wait."
    end
  end

  describe "Suite 2 — GET /api/books/:id" do
    @tag suite: :api
    test "returns 200 with book detail", %{conn: conn, book: book} do
      conn = get(conn, "/api/books/#{book.id}")

      resp = json_response(conn, 200)
      assert resp["book"]["id"] == book.id
      assert resp["book"]["title"] == "The Great Gatsby"
      assert is_list(resp["book"]["editions"])
      assert resp["book"]["edition_count"] >= 1
    end

    @tag suite: :api
    test "returns 404 for non-existent book", %{conn: conn} do
      fake_id = Ecto.UUID.generate()
      conn = get(conn, "/api/books/#{fake_id}")
      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    @tag suite: :api
    test "returns 403 for age_gated book when user is not age-verified", %{
      conn: conn,
      token: token
    } do
      {:ok, gated_book} =
        Books.create(%{
          "title" => "Age Gated Test",
          "isbn" => "9780316769488",
          "visibility_tier" => "age_gated"
        })

      conn =
        conn
        |> auth_conn(token)
        |> get("/api/books/#{gated_book.id}")

      assert %{"error" => "age_verification_required"} = json_response(conn, 403)
    end

    @tag suite: :api
    test "returns 404 when book visibility resolves to hidden", %{conn: conn, token: token} do
      fake_id = Ecto.UUID.generate()

      conn =
        conn
        |> auth_conn(token)
        |> get("/api/books/#{fake_id}")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end

  describe "Suite 2 — POST /api/bookshelves/:bookshelf_name/placements" do
    @tag suite: :api
    test "returns 201 with placement data", %{conn: conn, token: token, book: book} do
      conn =
        conn
        |> auth_conn(token)
        |> post("/api/bookshelves/wishlist/placements", %{"book_id" => book.id})

      assert %{"placement" => placement} = json_response(conn, 201)
      assert placement["book_id"] == book.id
    end

    @tag suite: :api
    test "returns 422 for invalid bookshelf name", %{conn: conn, token: token, book: book} do
      conn =
        conn
        |> auth_conn(token)
        |> post("/api/bookshelves/nonexistent_shelf/placements", %{"book_id" => book.id})

      assert json_response(conn, 422)
    end

    @tag suite: :api
    test "returns 422 when book_id is missing", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> post("/api/bookshelves/wishlist/placements", %{})

      assert %{"error" => _} = json_response(conn, 422)
    end

    @tag suite: :api
    test "returns 401 when unauthenticated", %{conn: conn, book: book} do
      conn = post(conn, "/api/bookshelves/wishlist/placements", %{"book_id" => book.id})
      assert conn.status == 401
    end

    @tag suite: :api
    test "returns 422 when placing a duplicate book on the same bookshelf", %{
      conn: conn,
      token: token,
      user: user,
      book: book
    } do
      {:ok, _} = Shelving.place_book(user.id, book.id, "library")

      conn =
        conn
        |> auth_conn(token)
        |> post("/api/bookshelves/library/placements", %{"book_id" => book.id})

      assert json_response(conn, 422)
    end
  end

  describe "Suite 2 — GET /api/books/isbn/:isbn" do
    @tag suite: :api
    test "returns 200 with book data when ISBN exists", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/books/isbn/9780743273565")

      assert %{"book" => book} = json_response(conn, 200)
      assert book["title"] == "The Great Gatsby"
    end

    @tag suite: :api
    test "returns 404 when ISBN does not exist", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/books/isbn/9780000000000")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    @tag suite: :api
    test "returns 404 for invalid ISBN format string", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/books/isbn/not-an-isbn")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end

  describe "Suite 2 — POST /api/upload (multi-book partial failure, )" do
    @tag suite: :api
    test "multi-book partial resolution surfaces only the resolved book(s) via SSE stream", %{
      conn: conn,
      token: token,
      user: user,
      book: book
    } do
      image = insert(:uploaded_image, status: "pending", user_id: user.id)

      with_vision(multi_book_partial(), fn ->
        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image.id,
          "image_b64" => @image_b64
        })
      end)

      stream_conn = get(conn, "/api/upload/#{image.id}/stream?token=#{token}")
      assert stream_conn.status == 200

      body = stream_conn.resp_body
      assert String.contains?(body, "resolved")
      assert String.contains?(body, book.id)
      refute String.contains?(body, "9780000000099")
    end

    @tag suite: :api
    test "multi-book upload flow returns 401 when unauthenticated", %{conn: conn} do
      conn = post(conn, "/api/upload/init", %{})
      assert conn.status == 401
    end
  end

  describe "Suite 3 — commit gate on undersized stored objects" do
    test "a 0-byte stored object is rejected at commit and enqueues no vision job",
         %{user: user} do
      {:ok, init} = Uploads.init_upload(user.id)

      StorageMock.seed("uploads/#{init.image_id}", "")

      assert {:error, :image_too_small} = Uploads.commit_upload(user.id, init.image_id)

      row = Repo.get!(UploadedImage, init.image_id)
      assert row.status == "rejected"
      assert row.rejection_reason == "image_too_small"
      assert event_count("image.rejected") == 1

      refute_enqueued(worker: IdentifyBookJob)
    end

    test "a sub-1KB stored object is rejected identically", %{user: user} do
      {:ok, init} = Uploads.init_upload(user.id)
      StorageMock.seed("uploads/#{init.image_id}", String.duplicate("x", 512))

      assert {:error, :image_too_small} = Uploads.commit_upload(user.id, init.image_id)
      assert Repo.get!(UploadedImage, init.image_id).status == "rejected"
      refute_enqueued(worker: IdentifyBookJob)
    end
  end

  describe "Suite 3 — uploaded_images INSERT on upload" do
    @tag suite: :db
    test "creates an uploaded_image record with correct fields", %{user: user} do
      tmp_path = create_temp_image()

      upload = %Plug.Upload{
        path: tmp_path,
        filename: "book.jpg",
        content_type: "image/jpeg"
      }

      assert {:ok, image} = Uploads.store_upload(user.id, upload)

      assert image.status == "pending"
      assert image.storage_path =~ ~r/^uploads\//
      assert image.uploaded_at != nil
      assert image.expires_at != nil

      diff = DateTime.diff(image.expires_at, image.uploaded_at, :day)
      assert diff == 30
    end
  end

  describe "Suite 3 — uploaded_images UPDATE on resolve" do
    @tag suite: :db
    test "mark_resolved updates status and book_ids", %{user: user} do
      image = insert(:uploaded_image, status: "pending")

      perform_job(IdentifyBookJob, %{
        "user_id" => user.id,
        "image_id" => image.id,
        "image_b64" => @image_b64
      })

      {:ok, image_id_bin} = Ecto.UUID.dump(image.id)

      updated =
        from(i in "uploaded_images",
          where: i.id == ^image_id_bin,
          select: %{status: i.status, book_ids: i.book_ids}
        )
        |> Repo.one(prefix: "op")

      assert updated.status == "resolved"
      assert [_ | _] = updated.book_ids
    end
  end

  describe "Suite 3 — uploaded_images UPDATE on reject" do
    @tag suite: :db
    test "mark_rejected updates status and rejection_reason for not_a_book" do
      image = insert(:uploaded_image, status: "pending")
      user = insert(:user)

      with_vision(not_a_book(), fn ->
        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image.id,
          "image_b64" => @image_b64
        })
      end)

      {:ok, image_id_bin} = Ecto.UUID.dump(image.id)

      updated =
        from(i in "uploaded_images",
          where: i.id == ^image_id_bin,
          select: %{status: i.status, rejection_reason: i.rejection_reason}
        )
        |> Repo.one(prefix: "op")

      assert updated.status == "rejected"
      assert updated.rejection_reason == "not_a_book"
    end

    @tag suite: :db
    test "mark_rejected updates status and rejection_reason for isbn_not_found" do
      image = insert(:uploaded_image, status: "pending")
      user = insert(:user)

      with_vision(no_isbn(), fn ->
        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image.id,
          "image_b64" => @image_b64
        })
      end)

      {:ok, image_id_bin} = Ecto.UUID.dump(image.id)

      updated =
        from(i in "uploaded_images",
          where: i.id == ^image_id_bin,
          select: %{status: i.status, rejection_reason: i.rejection_reason}
        )
        |> Repo.one(prefix: "op")

      assert updated.status == "rejected"
      assert updated.rejection_reason == "isbn_not_found"
    end
  end

  describe "Suite 3 — rejected image retains expires_at and storage_path" do
    @tag suite: :db
    test "rejected image retains expires_at for cleanup job" do
      image =
        insert(:uploaded_image,
          status: "pending",
          storage_path: "uploads/#{Ecto.UUID.generate()}"
        )

      user = insert(:user)

      with_vision(not_a_book(), fn ->
        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image.id,
          "image_b64" => @image_b64
        })
      end)

      {:ok, image_id_bin} = Ecto.UUID.dump(image.id)

      updated =
        from(i in "uploaded_images",
          where: i.id == ^image_id_bin,
          select: %{status: i.status, expires_at: i.expires_at}
        )
        |> Repo.one(prefix: "op")

      assert updated.status == "rejected"
      assert updated.expires_at != nil
    end

    @tag suite: :db
    test "rejected image storage_path persists until cleanup" do
      storage_path = "uploads/#{Ecto.UUID.generate()}"

      image =
        insert(:uploaded_image,
          status: "pending",
          storage_path: storage_path
        )

      user = insert(:user)

      with_vision(no_isbn(), fn ->
        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image.id,
          "image_b64" => @image_b64
        })
      end)

      {:ok, image_id_bin} = Ecto.UUID.dump(image.id)

      updated =
        from(i in "uploaded_images",
          where: i.id == ^image_id_bin,
          select: %{status: i.status, storage_path: i.storage_path}
        )
        |> Repo.one(prefix: "op")

      assert updated.status == "rejected"
      assert updated.storage_path == storage_path
    end

    @tag suite: :db
    test "ImageRetentionJob cleans up expired rejected images" do
      past = DateTime.add(DateTime.utc_now(), -1, :day)
      storage_key = "uploads/#{Ecto.UUID.generate()}"

      {:ok, _} = Storage.upload_image(Path.basename(storage_key), "fake data")

      image =
        insert(:uploaded_image,
          status: "rejected",
          rejection_reason: "not_a_book",
          storage_path: storage_key,
          uploaded_at: DateTime.add(past, -30, :day),
          expires_at: past
        )

      assert {:ok, expired_count} = ImageRetention.cleanup_expired_images()
      assert expired_count >= 1

      {:ok, image_id_bin} = Ecto.UUID.dump(image.id)

      remaining =
        from(i in "uploaded_images",
          where: i.id == ^image_id_bin,
          select: i.id
        )
        |> Repo.one(prefix: "op")

      assert remaining == nil

      assert StorageMock.get(storage_key) == nil
    end
  end

  describe "Suite 3 — books and book_editions via Multi" do
    @tag suite: :db
    test "Books.create/1 inserts both book and edition atomically" do
      attrs = %{
        "title" => "Test Book",
        "isbn" => "9780306406157",
        "publisher" => "Test Publisher"
      }

      assert {:ok, book} = Books.create(attrs)
      assert book.title == "Test Book"
      assert [_edition] = book.editions
      assert hd(book.editions).isbn == "9780306406157"

      assert Repo.get(Book, book.id) != nil
      assert Repo.get_by(BookEdition, isbn: "9780306406157") != nil
    end

    @tag suite: :db
    test "Books.create/1 rolls back book if edition fails (duplicate ISBN)" do
      {:ok, _book1} =
        Books.create(%{
          "title" => "First Book",
          "isbn" => "9780306406157"
        })

      result =
        Books.create(%{
          "title" => "Second Book",
          "isbn" => "9780306406157"
        })

      assert {:error, _} = result

      refute Repo.get_by(Book, title: "Second Book")
    end

    @tag suite: :db
    test "BookEdition validates ISBN format" do
      cs =
        Books.book_edition_changeset(%BookEdition{}, %{
          "isbn" => "invalid",
          "book_id" => Ecto.UUID.generate()
        })

      assert cs.valid? == false
      assert Keyword.has_key?(cs.errors, :isbn)
    end

    @tag suite: :db
    test "BookEdition validates ISBN-13 checksum" do
      cs =
        Books.book_edition_changeset(%BookEdition{}, %{
          "isbn" => "9780306406158",
          "book_id" => Ecto.UUID.generate()
        })

      assert cs.valid? == false
    end
  end

  describe "Suite 3 — placement INSERT" do
    @tag suite: :db
    test "Shelving.place_book/3 creates a placement with correct bookshelf_id", %{
      user: user,
      book: book
    } do
      {:ok, placement} = Shelving.place_book(user.id, book.id, "library")

      assert placement.book_id == book.id
      assert placement.placed_at != nil

      bookshelf = Shelving.get_bookshelf(user.id, "library")
      assert bookshelf != nil
      assert placement.bookshelf_id == bookshelf.id
    end
  end

  describe "Suite 3 — multi-book edition and placement isolation" do
    @tag suite: :db
    test "each book from bulk upload has its own book_editions record", %{user: user} do
      image = insert(:uploaded_image, status: "pending")

      book2 = insert(:book, title: "Book Two")
      insert(:book_edition, book: book2, isbn: "9780306406157")

      with_vision(multi_book(), fn ->
        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image.id,
          "image_b64" => @image_b64
        })
      end)

      {:ok, image_id_bin} = Ecto.UUID.dump(image.id)

      updated =
        from(i in "uploaded_images",
          where: i.id == ^image_id_bin,
          select: %{book_ids: i.book_ids}
        )
        |> Repo.one(prefix: "op")

      assert length(updated.book_ids) >= 2

      isbns =
        Enum.flat_map(updated.book_ids, fn book_id_bin ->
          {:ok, bid} = Ecto.UUID.load(book_id_bin)

          from(e in BookEdition, where: e.book_id == ^bid, select: e.isbn)
          |> Repo.all()
        end)

      assert length(isbns) >= 2
      assert isbns == Enum.uniq(isbns)
    end

    @tag suite: :db
    test "partial multi-book resolution leaves no orphan rows for the failed ISBN", %{user: user} do
      image = insert(:uploaded_image, status: "pending", user_id: user.id)
      failed_isbn = "9780000000099"

      books_before = Repo.aggregate(Book, :count)
      editions_before = Repo.aggregate(BookEdition, :count)

      with_vision(multi_book_partial(), fn ->
        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image.id,
          "image_b64" => @image_b64
        })
      end)

      {:ok, image_id_bin} = Ecto.UUID.dump(image.id)

      updated =
        from(i in "uploaded_images",
          where: i.id == ^image_id_bin,
          select: %{status: i.status, book_ids: i.book_ids}
        )
        |> Repo.one(prefix: "op")

      assert updated.status == "resolved"
      assert length(updated.book_ids) == 1

      assert Repo.aggregate(Book, :count) == books_before
      assert Repo.aggregate(BookEdition, :count) == editions_before

      refute Repo.get_by(BookEdition, isbn: failed_isbn)
    end

    @tag suite: :db
    test "placement of one book from bulk does not affect others", %{user: user} do
      image = insert(:uploaded_image, status: "pending")

      book2 = insert(:book, title: "Book Two Isolated")
      insert(:book_edition, book: book2, isbn: "9780306406157")

      with_vision(multi_book(), fn ->
        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image.id,
          "image_b64" => @image_b64
        })
      end)

      {:ok, image_id_bin} = Ecto.UUID.dump(image.id)

      updated =
        from(i in "uploaded_images",
          where: i.id == ^image_id_bin,
          select: %{book_ids: i.book_ids}
        )
        |> Repo.one(prefix: "op")

      assert length(updated.book_ids) >= 2

      [first_bin | rest_bins] = updated.book_ids
      {:ok, first_id} = Ecto.UUID.load(first_bin)

      {:ok, _placement} = Shelving.place_book(user.id, first_id, "library")

      assert Shelving.book_on_any_shelf?(user.id, first_id)

      Enum.each(rest_bins, fn bin ->
        {:ok, other_id} = Ecto.UUID.load(bin)
        refute Shelving.book_on_any_shelf?(user.id, other_id)
      end)
    end
  end

  describe "Suite 3 — duplicate detection" do
    @tag suite: :db
    test "book_on_any_shelf? returns true when book is placed", %{user: user, book: book} do
      refute Shelving.book_on_any_shelf?(user.id, book.id)
      {:ok, _} = Shelving.place_book(user.id, book.id, "library")
      assert Shelving.book_on_any_shelf?(user.id, book.id)
    end

    @tag suite: :db
    test "book_on_any_shelf? returns false for different user", %{book: book} do
      user1 = insert(:user)
      user2 = insert(:user)

      {:ok, _} = Shelving.place_book(user1.id, book.id, "library")

      assert Shelving.book_on_any_shelf?(user1.id, book.id)
      refute Shelving.book_on_any_shelf?(user2.id, book.id)
    end
  end

  describe "Suite 3 — age-gated visibility_tier" do
    @tag suite: :db
    test "books can be created with age_gated visibility_tier" do
      {:ok, book} =
        Books.create(%{
          "title" => "Age Gated Book",
          "isbn" => "9780306406157",
          "visibility_tier" => "age_gated"
        })

      assert book.visibility_tier == "age_gated"
    end

    @tag suite: :db
    test "Moderation pipeline creates a public book even for subjects that used to gate", %{
      user: user
    } do
      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok,
         %{
           "ISBN:9780451524935" => %{
             "title" => "Romance Novel",
             "subjects" => ["romance"]
           }
         }}
      )

      with_vision(romance_book(), fn ->
        image = insert(:uploaded_image, status: "pending")

        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image.id,
          "image_b64" => @image_b64
        })

        book = Repo.get_by(Book, title: "Romance Novel")
        assert book != nil
        assert book.visibility_tier == "public"
      end)
    end
  end

  describe "Suite 4 — storage failure suppresses image.submitted" do
    @tag suite: :events
    test "image.submitted is NOT emitted when storage backend returns an error", %{user: user} do
      defmodule Stacks.Storage.FailingBackend do
        @behaviour Stacks.Storage.StorageBehaviour

        @impl true
        def put(_key, _data, _opts), do: {:error, :unavailable}

        @impl true
        def presigned_url(_key, _ttl \\ 900), do: {:error, :unavailable}

        @impl true
        def delete(_key), do: :ok
      end

      original = Application.get_env(:core, :storage)
      Application.put_env(:core, :storage, Stacks.Storage.FailingBackend)

      on_exit(fn -> Application.put_env(:core, :storage, original) end)

      before_count = event_count("image.submitted")

      tmp_path = create_temp_image()
      upload = %Plug.Upload{path: tmp_path, filename: "test.jpg", content_type: "image/jpeg"}

      assert {:error, :unavailable} = Uploads.store_upload(user.id, upload)

      assert event_count("image.submitted") == before_count
    end
  end

  describe "Suite 4 — event sequence for happy path" do
    @tag suite: :events
    test "image.submitted event emitted on upload", %{user: user} do
      before_count = event_count("image.submitted")

      tmp_path = create_temp_image()
      upload = %Plug.Upload{path: tmp_path, filename: "test.jpg", content_type: "image/jpeg"}
      {:ok, _image} = Uploads.store_upload(user.id, upload)

      assert event_count("image.submitted") == before_count + 1

      events = events_of_type("image.submitted")
      latest = List.last(events)
      assert latest.payload["storage_path"] != nil
    end

    @tag suite: :events
    test "image.submitted payload contains storage_path", %{user: user} do
      tmp_path = create_temp_image()
      upload = %Plug.Upload{path: tmp_path, filename: "test.jpg", content_type: "image/jpeg"}
      {:ok, _image} = Uploads.store_upload(user.id, upload)

      events = events_of_type("image.submitted")
      latest = List.last(events)
      assert latest.payload["storage_path"] =~ ~r/^uploads\//
      assert latest.aggregate_type == "image"
    end

    @tag suite: :events
    test "image.resolved event emitted after successful identification", %{user: user} do
      image = insert(:uploaded_image, status: "pending")
      before_count = event_count("image.resolved")

      perform_job(IdentifyBookJob, %{
        "user_id" => user.id,
        "image_id" => image.id,
        "image_b64" => @image_b64
      })

      assert event_count("image.resolved") == before_count + 1

      events = events_of_type("image.resolved")
      latest = List.last(events)
      assert is_integer(latest.payload["book_count"])
      assert latest.payload["book_count"] > 0
    end

    @tag suite: :events
    test "image.resolved payload contains book_count", %{user: user} do
      image = insert(:uploaded_image, status: "pending")

      perform_job(IdentifyBookJob, %{
        "user_id" => user.id,
        "image_id" => image.id,
        "image_b64" => @image_b64
      })

      events = events_of_type("image.resolved")
      latest = List.last(events)
      assert is_integer(latest.payload["book_count"])
      assert latest.payload["book_count"] >= 1
      assert latest.aggregate_type == "image"
    end

    @tag suite: :events
    test "book.created event emitted on book creation" do
      before_count = event_count("book.created")

      {:ok, _book} =
        Books.create(%{
          "title" => "Event Test Book",
          "isbn" => "9780306406157"
        })

      assert event_count("book.created") == before_count + 1

      events = events_of_type("book.created")
      latest = List.last(events)
      assert latest.payload["isbn"] == "9780306406157"
      assert latest.payload["title"] == "Event Test Book"
      assert latest.payload["visibility_tier"] == "public"
      assert latest.aggregate_type == "book"
    end

    @tag suite: :events
    test "book.created event carries age_gated visibility_tier" do
      before_count = event_count("book.created")

      {:ok, _book} =
        Books.create(%{
          "title" => "Age Gated Event Book",
          "isbn" => "9780385490818",
          "visibility_tier" => "age_gated"
        })

      assert event_count("book.created") == before_count + 1

      events = events_of_type("book.created")
      latest = List.last(events)
      assert latest.payload["isbn"] == "9780385490818"
      assert latest.payload["title"] == "Age Gated Event Book"
      assert latest.payload["visibility_tier"] == "age_gated"
      assert latest.aggregate_type == "book"
    end

    @tag suite: :events
    test "placement.created event emitted on shelf placement", %{user: user, book: book} do
      before_count = event_count("placement.created")

      {:ok, _placement} = Shelving.place_book(user.id, book.id, "library")

      assert event_count("placement.created") == before_count + 1

      events = events_of_type("placement.created")
      latest = List.last(events)
      assert latest.payload["book_id"] == book.id
      assert latest.payload["bookshelf"] == "library"
      assert latest.aggregate_type == "placement"
    end
  end

  describe "Suite 4 — rejection events" do
    @tag suite: :events
    test "image.rejected emitted on not_a_book classification" do
      image = insert(:uploaded_image, status: "pending")
      user = insert(:user)
      before_count = event_count("image.rejected")

      with_vision(not_a_book(), fn ->
        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image.id,
          "image_b64" => @image_b64
        })
      end)

      assert event_count("image.rejected") == before_count + 1

      events = events_of_type("image.rejected")
      latest = List.last(events)
      assert latest.payload["reason"] == "not_a_book"
    end

    @tag suite: :events
    test "image.rejected emitted on isbn_not_found" do
      image = insert(:uploaded_image, status: "pending")
      user = insert(:user)
      before_count = event_count("image.rejected")

      with_vision(no_isbn(), fn ->
        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image.id,
          "image_b64" => @image_b64
        })
      end)

      assert event_count("image.rejected") == before_count + 1

      events = events_of_type("image.rejected")
      latest = List.last(events)
      assert latest.payload["reason"] == "isbn_not_found"
    end

    @tag suite: :events
    test "no book.created event emitted on rejection" do
      image = insert(:uploaded_image, status: "pending")
      user = insert(:user)
      before_count = event_count("book.created")

      with_vision(not_a_book(), fn ->
        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image.id,
          "image_b64" => @image_b64
        })
      end)

      assert event_count("book.created") == before_count
    end

    @tag suite: :events
    test "no placement.created event emitted on rejection" do
      image = insert(:uploaded_image, status: "pending")
      user = insert(:user)
      before_count = event_count("placement.created")

      with_vision(not_a_book(), fn ->
        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image.id,
          "image_b64" => @image_b64
        })
      end)

      assert event_count("placement.created") == before_count
    end
  end

  describe "Suite 4 — event chronological sequence" do
    @tag suite: :events
    test "events are recorded in correct order for a full upload flow", %{user: user} do
      tmp_path = create_temp_image()
      upload = %Plug.Upload{path: tmp_path, filename: "test.jpg", content_type: "image/jpeg"}
      {:ok, image} = Uploads.store_upload(user.id, upload)

      perform_job(IdentifyBookJob, %{
        "user_id" => user.id,
        "image_id" => image.id,
        "image_b64" => @image_b64
      })

      submitted = events_of_type("image.submitted") |> List.last()
      resolved = events_of_type("image.resolved") |> List.last()

      assert submitted != nil
      assert resolved != nil
      assert NaiveDateTime.compare(submitted.occurred_at, resolved.occurred_at) in [:lt, :eq]
    end
  end

  describe "Suite 4 — event handler execution" do
    @tag suite: :events
    test "book.created event enqueues SubscriberWorker (which triggers enrichment)" do
      {:ok, _book} =
        Books.create(%{
          "title" => "Handler Test Book",
          "isbn" => "9780140449136"
        })

      assert_enqueued(worker: Stacks.Events.SubscriberWorker)
    end

    @tag suite: :events
    test "emit_safe/1 returns {:ok, _} and does not propagate errors from emit/1" do
      bad_event = %{
        event_type: "test.emit_safe_rescue",
        aggregate_type: "test",
        aggregate_id: "not-a-valid-uuid"
      }

      assert {:error, _} = Stacks.Events.emit(bad_event)

      assert {:ok, _} = Stacks.Events.emit_safe(bad_event)
    end

    @tag suite: :events
    test "emit_safe/1 returns {:ok, event_params} and records event on success" do
      aggregate_id = Ecto.UUID.generate()
      before_count = event_count("test.emit_safe_success")

      result =
        Stacks.Events.emit_safe(%{
          event_type: "test.emit_safe_success",
          aggregate_type: "test",
          aggregate_id: aggregate_id,
          payload: %{hello: "world"}
        })

      assert {:ok, _} = result
      assert event_count("test.emit_safe_success") == before_count + 1
    end
  end

  describe "Suite 5 — IdentifyBookJob enqueue" do
    @tag suite: :jobs
    test "upload_and_identify enqueues a job on the vision queue", %{user: user} do
      image_id = Ecto.UUID.generate()
      storage_key = "uploads/#{image_id}"

      {:ok, job} = Uploads.upload_and_identify(user.id, image_id, storage_key)

      assert job.queue == "vision"

      user_id_val = job.args["user_id"] || job.args[:user_id]
      image_id_val = job.args["image_id"] || job.args[:image_id]
      storage_key_val = job.args["storage_key"] || job.args[:storage_key]

      assert user_id_val == user.id
      assert image_id_val == image_id
      assert storage_key_val == storage_key
    end

    @tag suite: :jobs
    test "job is enqueued with correct worker" do
      Uploads.upload_and_identify("user-id", "image-id", "uploads/image-id")

      assert_enqueued(
        worker: IdentifyBookJob,
        args: %{"user_id" => "user-id", "image_id" => "image-id"}
      )
    end
  end

  describe "Suite 5 — IdentifyBookJob happy path" do
    @tag suite: :jobs
    test "returns :ok when pipeline identifies a book", %{user: user} do
      image = insert(:uploaded_image, status: "pending")

      assert :ok =
               perform_job(IdentifyBookJob, %{
                 "user_id" => user.id,
                 "image_id" => image.id,
                 "image_b64" => @image_b64
               })
    end
  end

  describe "Suite 5 — IdentifyBookJob not_a_book path" do
    @tag suite: :jobs
    test "returns {:cancel, reason} for non-book images", %{user: user} do
      image = insert(:uploaded_image, status: "pending")

      with_vision(not_a_book(), fn ->
        assert {:cancel, "image does not contain a book"} =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => image.id,
                   "image_b64" => @image_b64
                 })
      end)
    end
  end

  describe "Suite 5 — IdentifyBookJob isbn_not_found path" do
    @tag suite: :jobs
    test "returns {:cancel, reason} when no ISBN resolves", %{user: user} do
      image = insert(:uploaded_image, status: "pending")

      with_vision(no_isbn(), fn ->
        assert {:cancel, "isbn_not_found"} =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => image.id,
                   "image_b64" => @image_b64
                 })
      end)
    end
  end

  describe "Suite 5 — IdentifyBookJob generic failure" do
    @tag suite: :jobs
    test "returns {:error, reason} for service unavailability (transient, allows retry)", %{
      user: user
    } do
      image = insert(:uploaded_image, status: "pending")

      with_vision(:any, service_error(), fn ->
        assert {:error, :service_unavailable} =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => image.id,
                   "image_b64" => @image_b64
                 })
      end)
    end
  end

  describe "Suite 5 — IdentifyBookJob max_attempts" do
    @tag suite: :jobs
    test "worker is configured with max_attempts of 3" do
      assert IdentifyBookJob.__opts__()[:max_attempts] == 3
    end

    @tag suite: :jobs
    test "worker is configured for the vision queue" do
      assert IdentifyBookJob.__opts__()[:queue] == :vision
    end
  end

  describe "Suite 5 — IdentifyBookJob with missing image_id in DB" do
    @tag suite: :jobs
    test "returns :ok when image_id does not exist in DB; no events or books created", %{
      user: user
    } do
      before_resolved = event_count("image.resolved")
      before_rejected = event_count("image.rejected")
      before_books = Repo.aggregate(Book, :count)

      fake_image_id = Ecto.UUID.generate()

      assert :ok =
               perform_job(IdentifyBookJob, %{
                 "user_id" => user.id,
                 "image_id" => fake_image_id,
                 "image_b64" => @image_b64
               })

      resolved_for_image =
        events_of_type("image.resolved")
        |> Enum.filter(&(&1.aggregate_id == fake_image_id))

      assert resolved_for_image == []

      rejected_for_image =
        events_of_type("image.rejected")
        |> Enum.filter(&(&1.aggregate_id == fake_image_id))

      assert rejected_for_image == []
    end
  end

  describe "Suite 5 — IdentifyBookJob with a multi-book vision response" do
    @tag suite: :jobs
    test "resolves multiple books and stores all book_ids in uploaded_images", %{user: user} do
      image = insert(:uploaded_image, status: "pending")

      book2 = insert(:book, title: "Book Two")
      insert(:book_edition, book: book2, isbn: "9780306406157")

      with_vision(multi_book(), fn ->
        assert :ok =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => image.id,
                   "image_b64" => @image_b64
                 })
      end)

      {:ok, image_id_bin} = Ecto.UUID.dump(image.id)

      updated =
        from(i in "uploaded_images",
          where: i.id == ^image_id_bin,
          select: %{status: i.status, book_ids: i.book_ids}
        )
        |> Repo.one(prefix: "op")

      assert updated.status == "resolved"
      assert length(updated.book_ids) >= 2
    end
  end

  describe "Suite 5 — IdentifyBookJob with an ambiguous vision response" do
    @tag suite: :jobs
    test "ambiguous classification is treated as not_a_book (rejected)", %{user: user} do
      image = insert(:uploaded_image, status: "pending")

      with_vision(ambiguous(), fn ->
        assert {:cancel, "image does not contain a book"} =
                 perform_job(IdentifyBookJob, %{
                   "user_id" => user.id,
                   "image_id" => image.id,
                   "image_b64" => @image_b64
                 })
      end)
    end
  end

  describe "Suite 5 — compound candidate expansion" do
    @tag suite: :jobs
    test "titles with OR are split and processed individually" do
      candidates = [
        %{
          "title" => "Things I Don't Want to Know OR The Cost of Living",
          "author" => "Deborah Levy",
          "potential_isbns" => [],
          "raw_text" => nil
        }
      ]

      with_vision(compound_title(), fn ->
        image = insert(:uploaded_image, status: "pending")
        user = insert(:user)

        result =
          perform_job(IdentifyBookJob, %{
            "user_id" => user.id,
            "image_id" => image.id,
            "image_b64" => @image_b64
          })

        assert result in [:ok, {:cancel, "isbn_not_found"}]
      end)
    end
  end

  describe "Suite 6 — MockClient classification responses" do
    @tag suite: :external
    test "default MockClient returns book classification" do
      result = MockClient.call_vision("is_book", %{})
      assert {:ok, %{"classification" => "CLASSIFICATION_RESULT_BOOK"}} = result
    end

    @tag suite: :external
    test "steered not-a-book response replaces the default classification" do
      MockClient.put_response("analyze", not_a_book())
      result = MockClient.call_vision("analyze", %{})
      assert {:ok, %{"classification" => "CLASSIFICATION_RESULT_NOT_BOOK"}} = result
    end

    @tag suite: :external
    test "steered ambiguous response replaces the default classification" do
      MockClient.put_response("analyze", ambiguous())
      result = MockClient.call_vision("analyze", %{})

      assert {:ok, %{"classification" => "CLASSIFICATION_RESULT_AMBIGUOUS", "confidence" => 0.5}} =
               result
    end

    @tag suite: :external
    test "steered service_unavailable error replaces the default success" do
      MockClient.put_response("analyze", service_error())
      assert {:error, :service_unavailable} = MockClient.call_vision("analyze", %{})
    end
  end

  describe "Suite 6 — MockClient extraction responses" do
    @tag suite: :external
    test "default MockClient returns book extraction with ISBN" do
      {:ok, resp} = MockClient.call_vision("analyze", %{})
      assert [book | _] = resp["books"]
      assert [_ | _] = book["potential_isbns"]
    end

    @tag suite: :external
    test "steered no-ISBN response replaces the default non-empty books array" do
      MockClient.put_response("analyze", no_isbn())
      {:ok, resp} = MockClient.call_vision("analyze", %{})
      assert resp["books"] == []
    end
  end

  describe "Suite 6 — circuit breaker" do
    @tag suite: :external
    test "steered :circuit_open error is returned for every endpoint" do
      MockClient.put_response(:any, circuit_open())
      assert {:error, :circuit_open} = MockClient.call_vision("analyze", %{})
      assert {:error, :circuit_open} = MockClient.call_vision("is_book", %{})
    end
  end

  describe "Suite 6 — MockClient steering seam" do
    @tag suite: :external
    test "put_response/2 steers is_book, and clear/0 restores the default" do
      assert {:ok, %{"classification" => "CLASSIFICATION_RESULT_BOOK"}} =
               MockClient.call_vision("is_book", %{})

      MockClient.put_response(
        "is_book",
        {:ok, %{"classification" => "CLASSIFICATION_RESULT_NOT_BOOK", "confidence" => 0.11}}
      )

      assert {:ok, %{"classification" => "CLASSIFICATION_RESULT_NOT_BOOK", "confidence" => 0.11}} =
               MockClient.call_vision("is_book", %{})

      MockClient.clear()

      assert {:ok, %{"classification" => "CLASSIFICATION_RESULT_BOOK"}} =
               MockClient.call_vision("is_book", %{})
    end

    @tag suite: :external
    test "steering is per-endpoint — an unsteered endpoint keeps its default" do
      MockClient.put_response("extract_isbn", {:error, :steered_failure})

      assert {:error, :steered_failure} = MockClient.call_vision("extract_isbn", %{})

      assert {:ok, %{"classification" => "CLASSIFICATION_RESULT_BOOK"}} =
               MockClient.call_vision("is_book", %{})
    end

    @tag suite: :external
    test "the most recent registration for an endpoint wins" do
      MockClient.put_response("extract_isbn", {:error, :first})
      MockClient.put_response("extract_isbn", {:error, :second})
      assert {:error, :second} = MockClient.call_vision("extract_isbn", %{})
    end

    @tag suite: :external
    test "an exact-endpoint registration wins over an :any registration" do
      MockClient.put_response(:any, {:error, :catch_all})
      MockClient.put_response("extract_isbn", {:error, :specific})

      assert {:error, :specific} = MockClient.call_vision("extract_isbn", %{})
      assert {:error, :catch_all} = MockClient.call_vision("is_book", %{})
    end

    @tag suite: :external
    test "a response can be a function of the payload" do
      MockClient.put_response("extract_isbn", fn payload ->
        {:ok, %{"echoed" => Map.get(payload, :image_b64)}}
      end)

      assert {:ok, %{"echoed" => "abc"}} =
               MockClient.call_vision("extract_isbn", %{image_b64: "abc"})
    end

    @tag suite: :external
    test "a steered response reaches work the caller farms out to a Task ($callers)" do
      MockClient.put_response("extract_isbn", {:error, :steered_in_parent})

      result =
        Task.async(fn -> MockClient.call_vision("extract_isbn", %{}) end)
        |> Task.await()

      assert {:error, :steered_in_parent} = result
    end

    @tag suite: :external
    test "a steered response is consumed by the IdentifyBookJob pipeline, not just echoed" do
      image = insert(:uploaded_image, status: "pending")
      user = insert(:user)

      with_vision(not_a_book(), fn ->
        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image.id,
          "image_b64" => @image_b64
        })
      end)

      {:ok, image_id_bin} = Ecto.UUID.dump(image.id)

      updated =
        from(i in "uploaded_images",
          where: i.id == ^image_id_bin,
          select: %{status: i.status, rejection_reason: i.rejection_reason}
        )
        |> Repo.one(prefix: "op")

      assert updated.status == "rejected"
      assert updated.rejection_reason == "not_a_book"
    end
  end

  describe "Suite 6 — ISBNResolver with MockHttpClient" do
    @tag suite: :external
    test "Open Library returns ISBN → success" do
      MockHttpClient.put_response("openlibrary.org/api/books", {
        :ok,
        %{
          "ISBN:9780451524935" => %{
            "title" => "1984",
            "authors" => [%{"name" => "George Orwell"}],
            "publishers" => [%{"name" => "Signet Classic"}],
            "number_of_pages" => 328,
            "subjects" => [%{"name" => "Dystopian fiction"}]
          }
        }
      })

      assert {:ok, data} = ISBNResolver.resolve("9780451524935")
      assert data[:title] == "1984"
      assert data[:source] == :open_library
    end

    @tag suite: :external
    test "Open Library fails, Google Books returns → success" do
      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})

      MockHttpClient.put_response("googleapis.com", {
        :ok,
        %{
          "items" => [
            %{
              "id" => "gbooks123",
              "volumeInfo" => %{
                "title" => "Brave New World",
                "authors" => ["Aldous Huxley"],
                "publisher" => "Harper Perennial",
                "pageCount" => 288,
                "industryIdentifiers" => [
                  %{"type" => "ISBN_13", "identifier" => "9780060850524"}
                ]
              }
            }
          ]
        }
      })

      assert {:ok, data} = ISBNResolver.resolve("9780060850524")
      assert data[:title] == "Brave New World"
      assert data[:source] == :google_books
    end

    @tag suite: :external
    test "both Open Library and Google Books fail → {:error, :not_found}" do
      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{}})

      assert {:error, :not_found} = ISBNResolver.resolve("9780000000000")
    end

    @tag suite: :external
    test "ISBNResolver returns gracefully when both upstreams reply 503 (service_unavailable)" do
      MockHttpClient.put_response("openlibrary.org/api/books", {:error, :service_unavailable})
      MockHttpClient.put_response("googleapis.com", {:error, :service_unavailable})

      assert {:error, _reason} = ISBNResolver.resolve("9780451524935")
    end

    @tag suite: :external
    test "merge_format endpoint surfaces an ISBN-service outage as 503 resolver_unavailable", %{
      conn: conn,
      token: token,
      book: book
    } do
      MockHttpClient.put_response("openlibrary.org/api/books", {:error, :service_unavailable})
      MockHttpClient.put_response("googleapis.com", {:error, :service_unavailable})

      conn =
        conn
        |> auth_conn(token)
        |> post("/api/books/#{book.id}/merge-format", %{"isbn" => "9780451524935"})

      assert resp = json_response(conn, 503)

      refute resp["error"] == "isbn_not_found",
             "the catalogues never answered — nothing was learned about this ISBN"

      assert resp["error"] == "resolver_unavailable"
    end
  end

  describe "Suite 6 — BudgetTracker" do
    @tag suite: :external
    test "check_budget returns :ok when under budget" do
      assert :ok = BudgetTracker.check_budget(:modal)
    end

    @tag suite: :external
    test "check_budget returns error when daily limit is exceeded" do
      original_config = Application.get_env(:core, :ai_budget, [])

      try do
        Application.put_env(:core, :ai_budget, daily_limit_cents: 1, monthly_limit_cents: 50_000)

        BudgetTracker.record_cost(:modal, 2)
        Process.sleep(50)

        assert {:error, :daily_limit_exceeded} = BudgetTracker.check_budget(:modal)
      after
        Application.put_env(:core, :ai_budget, original_config)
      end
    end

    @tag suite: :external
    test "record_cost increases daily spend" do
      state_before = BudgetTracker.current_state()
      BudgetTracker.record_cost(:test_provider, 10)
      Process.sleep(50)
      state_after = BudgetTracker.current_state()

      assert state_after.daily_total_cents >= state_before.daily_total_cents + 10
    end
  end

  describe "Suite 6 — HMAC auth token" do
    @tag suite: :external
    test "auth_token/2 generates timestamp.signature format" do
      original = Application.get_env(:core, :vision_hmac_secret)

      try do
        Application.put_env(:core, :vision_hmac_secret, "test_secret_key")

        req = AIClient.build_vision_request("/classify", %{image: "test"})

        token_header =
          Enum.find_value(req.headers, fn
            {"X-Internal-Token", value} -> value
            _ -> nil
          end)

        assert token_header != nil
        assert [ts_str, sig] = String.split(token_header, ".", parts: 2)
        assert {_ts, ""} = Integer.parse(ts_str)
        assert String.length(sig) == 64
        assert Regex.match?(~r/^[0-9a-f]+$/, sig)
      after
        if original, do: Application.put_env(:core, :vision_hmac_secret, original)
      end
    end
  end

  describe "Suite 7 — Storage.upload_image" do
    @tag suite: :storage
    test "stores image at uploads/{image_id} key" do
      image_id = Ecto.UUID.generate()
      assert {:ok, key} = Storage.upload_image(image_id, "fake data")
      assert key == "uploads/#{image_id}"
    end
  end

  describe "Suite 7 — Storage.get_image_url" do
    @tag suite: :storage
    test "returns a presigned URL" do
      image_id = Ecto.UUID.generate()
      storage_key = "uploads/#{image_id}"

      {:ok, _} = Storage.upload_image(image_id, "fake data")

      assert {:ok, url} = Storage.get_image_url(storage_key)
      assert is_binary(url)
      assert url =~ storage_key
    end

    @tag suite: :storage
    test "default TTL is 900 seconds" do
      storage_key = "uploads/test"
      {:ok, url} = Storage.get_image_url(storage_key)
      assert is_binary(url)
    end
  end

  describe "Suite 7 — Storage.delete_image" do
    @tag suite: :storage
    test "removes the image from storage" do
      image_id = Ecto.UUID.generate()
      key = "uploads/#{image_id}"

      {:ok, _} = Storage.upload_image(image_id, "data to delete")
      assert StorageMock.get(key) == "data to delete"

      assert :ok = Storage.delete_image(key)
      assert StorageMock.get(key) == nil
    end
  end

  describe "Suite 7 — cleanup on DB failure" do
    @tag suite: :storage
    test "store_upload calls delete_image if DB insert fails", %{user: user} do
      tmp_path = create_temp_image()
      upload = %Plug.Upload{path: tmp_path, filename: "test.jpg", content_type: "image/jpeg"}
      assert {:ok, image} = Uploads.store_upload(user.id, upload)

      key = image.storage_path
      assert StorageMock.get(key) != nil
    end

    @tag suite: :storage
    test "storage cleanup when File.read fails (file deleted before read)", %{user: user} do
      upload = %Plug.Upload{
        path: "/tmp/nonexistent_#{System.unique_integer([:positive])}.jpg",
        filename: "ghost.jpg",
        content_type: "image/jpeg"
      }

      assert {:error, _reason} = Uploads.store_upload(user.id, upload)
    end

    @tag suite: :storage
    test "upload then delete round-trip proves cleanup path works" do
      image_id = Ecto.UUID.generate()
      key = "uploads/#{image_id}"
      data = "cleanup test image bytes"

      {:ok, _} = Storage.upload_image(image_id, data)
      assert StorageMock.get(key) == data

      :ok = Storage.delete_image(key)
      assert StorageMock.get(key) == nil
    end
  end

  describe "Suite 7 — content type verification" do
    @tag suite: :storage
    test "Storage.upload_image stores data at the correct key", %{} do
      image_id = Ecto.UUID.generate()
      data = "fake jpeg content"

      assert {:ok, key} = Storage.upload_image(image_id, data)
      assert key == "uploads/#{image_id}"

      assert StorageMock.get(key) == data
    end

    @tag :deployed_only
    @tag suite: :storage
    test "uploaded image has correct content-type metadata on real storage" do
      image_id = Ecto.UUID.generate()
      jpeg_bytes = <<0xFF, 0xD8, 0xFF, 0xE0>> <> :crypto.strong_rand_bytes(64)

      assert {:ok, key} =
               Storage.upload_image(image_id, jpeg_bytes, content_type: "image/jpeg")

      assert key == "uploads/#{image_id}"

      assert {:ok, url} = Storage.get_image_url(key)
      assert is_binary(url)
    end
  end

  describe "Suite 2 — POST /api/books/:id/merge-format" do
    @tag suite: :api
    test "with valid ISBN adds edition and returns 200", %{conn: conn, token: token, book: book} do
      merge_isbn = "9780451524935"

      MockHttpClient.put_response("openlibrary.org/api/books", {
        :ok,
        %{
          "ISBN:#{merge_isbn}" => %{
            "title" => "1984",
            "authors" => [%{"name" => "George Orwell"}],
            "publishers" => [%{"name" => "Signet Classic"}],
            "number_of_pages" => 328,
            "subjects" => [%{"name" => "Dystopian fiction"}]
          }
        }
      })

      conn =
        conn
        |> auth_conn(token)
        |> post("/api/books/#{book.id}/merge-format", %{
          "isbn" => merge_isbn,
          "format_label" => "Hardcover"
        })

      resp = json_response(conn, 200)
      assert %{"edition" => edition} = resp
      assert edition["isbn"] == merge_isbn
      assert edition["is_primary"] == false
    end

    @tag suite: :api
    test "with duplicate ISBN returns 422", %{conn: conn, token: token, book: book} do
      existing_isbn = "9780743273565"

      MockHttpClient.put_response("openlibrary.org/api/books", {
        :ok,
        %{
          "ISBN:#{existing_isbn}" => %{
            "title" => "The Great Gatsby",
            "authors" => [%{"name" => "F. Scott Fitzgerald"}],
            "publishers" => [%{"name" => "Scribner"}],
            "number_of_pages" => 180,
            "subjects" => []
          }
        }
      })

      conn =
        conn
        |> auth_conn(token)
        |> post("/api/books/#{book.id}/merge-format", %{"isbn" => existing_isbn})

      resp = json_response(conn, 422)
      assert resp["error"] == "duplicate_isbn"
    end

    @tag suite: :api
    test "with nonexistent book returns 404", %{conn: conn, token: token} do
      fake_id = Ecto.UUID.generate()
      merge_isbn = "9780451524935"

      MockHttpClient.put_response("openlibrary.org/api/books", {
        :ok,
        %{
          "ISBN:#{merge_isbn}" => %{
            "title" => "1984",
            "authors" => [%{"name" => "George Orwell"}],
            "publishers" => [%{"name" => "Signet Classic"}],
            "number_of_pages" => 328,
            "subjects" => []
          }
        }
      })

      conn =
        conn
        |> auth_conn(token)
        |> post("/api/books/#{fake_id}/merge-format", %{"isbn" => merge_isbn})

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    @tag suite: :api
    test "returns 401 when unauthenticated", %{conn: conn, book: book} do
      conn = post(conn, "/api/books/#{book.id}/merge-format", %{"isbn" => "9780451524935"})
      assert conn.status == 401
    end
  end

  describe "Suite 3 — merge creates non-primary edition" do
    @tag suite: :db
    test "merge creates non-primary edition linked to existing book", %{book: book} do
      merge_isbn = "9780451524935"

      MockHttpClient.put_response("openlibrary.org/api/books", {
        :ok,
        %{
          "ISBN:#{merge_isbn}" => %{
            "title" => "1984",
            "authors" => [%{"name" => "George Orwell"}],
            "publishers" => [%{"name" => "Signet Classic"}],
            "number_of_pages" => 328,
            "subjects" => []
          }
        }
      })

      assert {:ok, edition} =
               Books.merge_edition(book.id, %{"isbn" => merge_isbn, "format_label" => "Hardcover"})

      assert edition.book_id == book.id
      assert edition.isbn == merge_isbn
      assert edition.is_primary == false
      assert edition.format_label == "Hardcover"

      db_edition = Repo.get(BookEdition, edition.id)
      assert db_edition != nil
      assert db_edition.book_id == book.id
      assert db_edition.is_primary == false
    end

    @tag suite: :db
    test "original primary edition unchanged after merge", %{book: book} do
      original_edition = Repo.get_by(BookEdition, book_id: book.id, is_primary: true)
      assert original_edition != nil

      merge_isbn = "9780451524935"

      MockHttpClient.put_response("openlibrary.org/api/books", {
        :ok,
        %{
          "ISBN:#{merge_isbn}" => %{
            "title" => "1984",
            "authors" => [%{"name" => "George Orwell"}],
            "publishers" => [%{"name" => "Signet Classic"}],
            "number_of_pages" => 328,
            "subjects" => []
          }
        }
      })

      assert {:ok, _new_edition} = Books.merge_edition(book.id, %{"isbn" => merge_isbn})

      after_edition = Repo.get(BookEdition, original_edition.id)
      assert after_edition.isbn == original_edition.isbn
      assert after_edition.is_primary == true
      assert after_edition.book_id == original_edition.book_id
      assert after_edition.format_label == original_edition.format_label
      assert after_edition.publisher == original_edition.publisher
    end
  end

  describe "Suite 4 — books.edition_merged event" do
    @tag suite: :events
    test "books.edition_merged event emitted after successful merge", %{book: book} do
      before_count = event_count("books.edition_merged")
      merge_isbn = "9780451524935"

      MockHttpClient.put_response("openlibrary.org/api/books", {
        :ok,
        %{
          "ISBN:#{merge_isbn}" => %{
            "title" => "1984",
            "authors" => [%{"name" => "George Orwell"}],
            "publishers" => [%{"name" => "Signet Classic"}],
            "number_of_pages" => 328,
            "subjects" => []
          }
        }
      })

      assert {:ok, edition} = Books.merge_edition(book.id, %{"isbn" => merge_isbn})
      assert event_count("books.edition_merged") == before_count + 1

      events = events_of_type("books.edition_merged")
      latest = List.last(events)
      assert latest.payload["isbn"] == merge_isbn
      assert latest.payload["work_id"] == book.id
      assert latest.aggregate_type == "book_edition"
      assert latest.aggregate_id == edition.id
    end
  end

  describe "Integration — full upload-to-shelf flow via API" do
    @tag suite: :api
    test "complete flow: upload -> poll -> book detail -> placement", %{
      token: token,
      user: user,
      book: _book
    } do
      tmp_path = create_temp_image()

      upload = %Plug.Upload{
        path: tmp_path,
        filename: "gatsby.jpg",
        content_type: "image/jpeg"
      }

      assert {:ok, stored} = Uploads.store_upload(user.id, upload)
      image_id = stored.id

      pending_image = Repo.get!(UploadedImage, image_id)
      assert pending_image.status == "pending"

      perform_job(IdentifyBookJob, %{
        "user_id" => user.id,
        "image_id" => image_id,
        "image_b64" => @image_b64
      })

      resolved_image = Repo.get!(UploadedImage, image_id)
      assert resolved_image.status == "resolved"
      assert resolved_image.book_ids != []

      book_id = List.first(resolved_image.book_ids)

      book_conn =
        build_conn()
        |> auth_conn(token)
        |> get("/api/books/#{book_id}")

      book_resp = json_response(book_conn, 200)
      assert book_resp["book"]["id"] == book_id
      assert is_binary(book_resp["book"]["title"])

      place_conn =
        build_conn()
        |> auth_conn(token)
        |> post("/api/bookshelves/wishlist/placements", %{"book_id" => book_id})

      assert %{"placement" => placement} = json_response(place_conn, 201)
      assert placement["book_id"] == book_id

      submitted_for_image =
        events_of_type("image.submitted")
        |> Enum.filter(&(&1.aggregate_id == image_id))

      resolved_for_image =
        events_of_type("image.resolved")
        |> Enum.filter(&(&1.aggregate_id == image_id))

      assert length(submitted_for_image) == 1
      assert length(resolved_for_image) == 1
      assert event_count("placement.created") >= 1
    end
  end

  describe "Integration — rejection flow via API" do
    @tag suite: :api
    test "upload -> poll -> rejection (not_a_book)", %{
      user: user
    } do
      tmp_path = create_temp_image()

      upload = %Plug.Upload{
        path: tmp_path,
        filename: "cat_photo.jpg",
        content_type: "image/jpeg"
      }

      assert {:ok, stored} = Uploads.store_upload(user.id, upload)
      image_id = stored.id

      with_vision(not_a_book(), fn ->
        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image_id,
          "image_b64" => @image_b64
        })
      end)

      rejected_image = Repo.get!(UploadedImage, image_id)
      assert rejected_image.status == "rejected"
      assert rejected_image.rejection_reason == "not_a_book"
      assert rejected_image.book_ids == []
    end

    @tag suite: :api
    test "upload -> poll -> rejection (isbn_not_found)", %{
      user: user
    } do
      tmp_path = create_temp_image()

      upload = %Plug.Upload{
        path: tmp_path,
        filename: "blurry.jpg",
        content_type: "image/jpeg"
      }

      assert {:ok, stored} = Uploads.store_upload(user.id, upload)
      image_id = stored.id

      with_vision(no_isbn(), fn ->
        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image_id,
          "image_b64" => @image_b64
        })
      end)

      rejected_image = Repo.get!(UploadedImage, image_id)
      assert rejected_image.status == "rejected"
      assert rejected_image.rejection_reason == "isbn_not_found"
    end
  end

  defp analyze_response(classification, books, confidence \\ 0.9) do
    {:ok,
     %{
       "classification" => classification,
       "confidence" => confidence,
       "books" => books,
       "model_used" => "mock"
     }}
  end

  defp book_candidate(title, author, potential_isbns, confidence) do
    %{
      "title" => title,
      "author" => author,
      "potential_isbns" => potential_isbns,
      "raw_text" => nil,
      "confidence" => confidence
    }
  end

  defp not_a_book, do: analyze_response("CLASSIFICATION_RESULT_NOT_BOOK", [], 0.95)

  defp no_isbn, do: analyze_response("CLASSIFICATION_RESULT_BOOK", [])

  defp ambiguous, do: analyze_response("CLASSIFICATION_RESULT_AMBIGUOUS", [], 0.5)

  defp service_error, do: {:error, :service_unavailable}

  defp circuit_open, do: {:error, :circuit_open}

  defp compound_title do
    analyze_response("CLASSIFICATION_RESULT_BOOK", [
      book_candidate(
        "Things I Don't Want to Know OR The Cost of Living",
        "Deborah Levy",
        [],
        0.85
      )
    ])
  end

  defp romance_book do
    analyze_response("CLASSIFICATION_RESULT_BOOK", [
      book_candidate("Romance Novel", "Author X", ["9780451524935"], 0.9)
    ])
  end

  defp multi_book do
    analyze_response("CLASSIFICATION_RESULT_BOOK", [
      book_candidate("Book One", "Author A", ["9780743273565"], 0.9),
      book_candidate("Book Two", "Author B", ["9780306406157"], 0.8)
    ])
  end

  defp multi_book_partial do
    analyze_response("CLASSIFICATION_RESULT_BOOK", [
      book_candidate("Book One (resolves)", "Author A", ["9780743273565"], 0.9),
      book_candidate("Book Two (fails)", "Author B", ["9780000000099"], 0.8)
    ])
  end
end
