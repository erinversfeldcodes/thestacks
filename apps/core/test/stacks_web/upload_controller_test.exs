defmodule StacksWeb.UploadControllerTest do
  use CoreWeb.ConnCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Books.TitleSearchCache
  alias Stacks.Books.UploadedImage
  alias Stacks.Storage.Mock, as: StorageMock
  alias Stacks.Workers.IdentifyBookJob

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, token, _} = Guardian.encode_and_sign(user)
    authed_conn = put_req_header(conn, "authorization", "Bearer #{token}")
    %{conn: authed_conn, user: user}
  end

  describe "POST /api/upload/init" do
    test "returns 201 with image_id + upload_url + expires_in", %{conn: conn} do
      conn = post(conn, "/api/upload/init", %{"content_type" => "image/jpeg"})

      assert %{
               "image_id" => image_id,
               "upload_url" => url,
               "expires_in" => expires_in
             } = json_response(conn, 201)

      assert is_binary(image_id)
      assert url == "/api/upload/#{image_id}/data"
      assert is_integer(expires_in) and expires_in > 0
    end

    test "inserts an UploadedImage row with status awaiting_upload", %{conn: conn, user: user} do
      conn = post(conn, "/api/upload/init", %{"content_type" => "image/jpeg"})
      %{"image_id" => image_id} = json_response(conn, 201)

      image = Core.Repo.get!(UploadedImage, image_id)
      assert image.status == "awaiting_upload"
      assert image.user_id == user.id
      assert image.storage_path == "uploads/#{image_id}"
    end

    test "defaults content_type to image/jpeg when absent", %{conn: conn} do
      conn = post(conn, "/api/upload/init", %{})
      assert %{"image_id" => _} = json_response(conn, 201)
    end

    test "returns 401 without auth token" do
      conn = build_conn() |> post("/api/upload/init", %{})
      assert json_response(conn, 401)
    end
  end

  describe "POST /api/upload/:id/commit" do
    setup %{user: user} do
      {:ok, init} = Stacks.Uploads.init_upload(user.id)
      {:ok, init: init}
    end

    test "returns 202 and enqueues IdentifyBookJob when R2 object exists", %{
      conn: conn,
      user: user,
      init: init
    } do
      StorageMock.seed("uploads/#{init.image_id}", String.duplicate("fake image bytes ", 128))

      conn = post(conn, "/api/upload/#{init.image_id}/commit", %{})

      assert %{"status" => "accepted", "image_id" => image_id} = json_response(conn, 202)
      assert image_id == init.image_id

      assert_enqueued(
        worker: IdentifyBookJob,
        args: %{"user_id" => user.id, "image_id" => init.image_id}
      )

      row = Core.Repo.get!(UploadedImage, init.image_id)
      assert row.status == "pending"
    end

    test "returns 409 not_yet_uploaded when R2 object is missing", %{conn: conn, init: init} do
      conn = post(conn, "/api/upload/#{init.image_id}/commit", %{})

      assert %{"error" => "not_yet_uploaded"} = json_response(conn, 409)

      refute_enqueued(worker: IdentifyBookJob, args: %{"image_id" => init.image_id})
    end

    test "returns 404 when image_id does not belong to the caller", %{init: init} do
      other = insert(:user)
      {:ok, other_token, _} = Guardian.encode_and_sign(other)
      other_conn = build_conn() |> put_req_header("authorization", "Bearer #{other_token}")

      StorageMock.seed("uploads/#{init.image_id}", "fake")
      conn = post(other_conn, "/api/upload/#{init.image_id}/commit", %{})

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "returns 422 image_too_small and rejects the row for an empty object", %{
      conn: conn,
      init: init
    } do
      StorageMock.seed("uploads/#{init.image_id}", "")

      conn = post(conn, "/api/upload/#{init.image_id}/commit", %{})

      assert %{"error" => "image_too_small"} = json_response(conn, 422)
      assert Core.Repo.get!(UploadedImage, init.image_id).status == "rejected"
      refute_enqueued(worker: IdentifyBookJob, args: %{"image_id" => init.image_id})
    end

    test "returns 409 already_committed on repeat commit", %{conn: conn, init: init} do
      StorageMock.seed("uploads/#{init.image_id}", String.duplicate("fake image bytes ", 128))
      post(conn, "/api/upload/#{init.image_id}/commit", %{})
      conn = post(conn, "/api/upload/#{init.image_id}/commit", %{})
      assert %{"error" => "already_committed"} = json_response(conn, 409)
    end

    test "returns 404 for unknown image_id", %{conn: conn} do
      conn = post(conn, "/api/upload/#{Ecto.UUID.generate()}/commit", %{})
      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end

  describe "GET /api/upload/:image_id/stream" do
    test "returns status for a pending image via SSE", %{user: user} do
      alias Stacks.Accounts.Guardian
      {:ok, token, _} = Guardian.encode_and_sign(user)

      image = insert(:uploaded_image, status: "pending", user_id: user.id)

      conn2 = get(build_conn(), "/api/upload/#{image.id}/stream?token=#{token}")
      assert conn2.status == 200
      [content_type | _] = get_resp_header(conn2, "content-type")
      assert String.contains?(content_type, "text/event-stream")
    end

    test "returns 404 for unknown image_id", %{user: user} do
      alias Stacks.Accounts.Guardian
      {:ok, token, _} = Guardian.encode_and_sign(user)

      conn = get(build_conn(), "/api/upload/#{Ecto.UUID.generate()}/stream?token=#{token}")
      assert json_response(conn, 404)
    end

    test "returns 400 for an invalid (non-UUID) image_id", %{user: user} do
      alias Stacks.Accounts.Guardian
      {:ok, token, _} = Guardian.encode_and_sign(user)

      conn = get(build_conn(), "/api/upload/not-a-uuid/stream?token=#{token}")
      assert conn.status in [400, 422]
    end

    test "returns 401 without auth token" do
      conn = get(build_conn(), "/api/upload/#{Ecto.UUID.generate()}/stream")
      assert json_response(conn, 401)
    end

    test "returns 403 when image is owned by a different user", %{user: _user} do
      alias Stacks.Accounts.Guardian

      owner = insert(:user)
      requester = insert(:user)
      {:ok, requester_token, _} = Guardian.encode_and_sign(requester)

      image = insert(:uploaded_image, status: "pending", user_id: owner.id)

      conn = get(build_conn(), "/api/upload/#{image.id}/stream?token=#{requester_token}")
      assert conn.status == 403
    end

    test "returns SSE event body for a resolved image", %{user: user} do
      alias Stacks.Accounts.Guardian
      {:ok, token, _} = Guardian.encode_and_sign(user)

      book = insert(:book)

      image =
        insert(:uploaded_image,
          status: "resolved",
          book_id: book.id,
          book_ids: [book.id],
          user_id: user.id
        )

      conn2 = get(build_conn(), "/api/upload/#{image.id}/stream?token=#{token}")
      assert conn2.status == 200
      assert String.contains?(conn2.resp_body, "resolved")
      assert String.contains?(conn2.resp_body, book.id)
    end

    test "returns SSE event body with singleton book_id when book_ids is empty", %{user: user} do
      alias Stacks.Accounts.Guardian
      {:ok, token, _} = Guardian.encode_and_sign(user)

      book = insert(:book)

      image =
        insert(:uploaded_image,
          status: "resolved",
          book_id: book.id,
          book_ids: [],
          user_id: user.id
        )

      conn2 = get(build_conn(), "/api/upload/#{image.id}/stream?token=#{token}")
      assert conn2.status == 200
      assert String.contains?(conn2.resp_body, "resolved")
      assert String.contains?(conn2.resp_body, book.id)
    end
  end

  describe "POST /api/upload/:image_id/reject-identification" do
    test "rejecting moves the image OUT of its terminal state, so the retry is real",
         %{conn: conn, user: user} do
      # Two consumers depend on this and both were broken while the row stayed
      # `resolved`:
      #
      #   * the SSE stream's terminal branch replays a resolved row immediately
      #     and closes — so the client's re-opened stream got the SAME rejected
      #     candidate back in under a second, and "No, try again" visibly did
      #     nothing (the retry's fresh answer landed nowhere the reader looked);
      #   * `mark_resolved/2` only writes `where status == "pending"` — so the
      #     retry job's result was silently DISCARDED: real GPU work, zero rows
      #     updated, no broadcast.
      author = insert(:author, name: "Wrong Author")
      book = insert(:book, title: "The Wrong Book", author: author)
      insert(:book_edition, book: book, isbn: "9780000000002")

      image =
        insert(:uploaded_image,
          status: "resolved",
          user_id: user.id,
          book_id: book.id,
          book_ids: [book.id],
          storage_path: "uploads/#{Ecto.UUID.generate()}"
        )

      post(conn, "/api/upload/#{image.id}/reject-identification", %{
        "rejected_book_ids" => [book.id]
      })

      reloaded = Core.Repo.get!(Stacks.Books.UploadedImage, image.id)

      assert reloaded.status == "pending",
             "the image must leave its terminal state on reject — a `resolved` row is " <>
               "replayed verbatim by the SSE stream and refused by mark_resolved's guard"

      assert reloaded.book_ids in [nil, []],
             "stale candidates must not survive the reject — any reader of book_ids " <>
               "would re-propose the book just rejected"

      assert is_nil(reloaded.book_id)
    end

    test "returns 202, enqueues IdentifyBookJob with excluded_books, and removes the prior placement",
         %{conn: conn, user: user} do
      author = insert(:author, name: "F. Scott Fitzgerald")
      book = insert(:book, title: "The Great Gatsby", author: author)
      insert(:book_edition, book: book, isbn: "9780743273565")

      image =
        insert(:uploaded_image,
          status: "resolved",
          user_id: user.id,
          book_id: book.id,
          book_ids: [book.id],
          storage_path: "uploads/#{Ecto.UUID.generate()}"
        )

      {:ok, _placement} = Stacks.Shelving.place_book(user.id, book.id, "library")

      conn =
        post(conn, "/api/upload/#{image.id}/reject-identification", %{
          "rejected_book_ids" => [book.id]
        })

      assert %{
               "status" => "pending",
               "excluded_books" => ["The Great Gatsby by F. Scott Fitzgerald"]
             } = json_response(conn, 202)

      assert_enqueued(
        worker: IdentifyBookJob,
        args: %{
          "user_id" => user.id,
          "image_id" => image.id,
          "excluded_books" => ["The Great Gatsby by F. Scott Fitzgerald"]
        }
      )

      assert Stacks.Shelving.get_placements_for_book(user.id, book.id) == []
    end

    test "a rejection withdraws only the newest placement, not the reader's own", %{
      conn: conn,
      user: user
    } do
      book = insert(:book, title: "Kept On Purpose")
      insert(:book_edition, book: book, isbn: "9780743273565")

      kept =
        insert(:placement, book: book, bookshelf: insert(:bookshelf, user: user, name: "library"))

      from_identification =
        insert(:placement,
          book: book,
          bookshelf: insert(:bookshelf, user: user, name: "wishlist")
        )

      image = insert(:uploaded_image, status: "resolved", user_id: user.id)

      conn =
        post(conn, "/api/upload/#{image.id}/reject-identification", %{
          "rejected_book_ids" => [book.id]
        })

      assert json_response(conn, 202)

      remaining = Stacks.Shelving.get_placements_for_book(user.id, book.id)
      assert Enum.map(remaining, & &1.id) == [kept.id]
      refute from_identification.id in Enum.map(remaining, & &1.id)
    end

    test "falls back to title-only descriptor when the book has no author", %{
      conn: conn,
      user: user
    } do
      book = insert(:book, title: "Untitled Volume", author: nil)
      insert(:book_edition, book: book, isbn: "9780743273565")

      image = insert(:uploaded_image, status: "resolved", user_id: user.id)

      conn =
        post(conn, "/api/upload/#{image.id}/reject-identification", %{
          "rejected_book_ids" => [book.id]
        })

      assert %{"excluded_books" => ["Untitled Volume"]} = json_response(conn, 202)
    end

    test "no prior placement is a no-op (still returns 202)", %{conn: conn, user: user} do
      author = insert(:author, name: "Some Author")
      book = insert(:book, title: "Some Book", author: author)
      insert(:book_edition, book: book, isbn: "9780743273565")
      image = insert(:uploaded_image, status: "resolved", user_id: user.id)

      conn =
        post(conn, "/api/upload/#{image.id}/reject-identification", %{
          "rejected_book_ids" => [book.id]
        })

      assert %{"status" => "pending"} = json_response(conn, 202)
    end

    test "returns 401 without auth token" do
      conn =
        build_conn()
        |> post("/api/upload/#{Ecto.UUID.generate()}/reject-identification", %{
          "rejected_book_ids" => []
        })

      assert json_response(conn, 401)
    end

    test "returns 404 when image_id belongs to a different user", %{conn: _conn, user: user} do
      other = insert(:user)
      author = insert(:author, name: "X")
      book = insert(:book, title: "Y", author: author)
      insert(:book_edition, book: book, isbn: "9780743273565")
      image = insert(:uploaded_image, status: "resolved", user_id: other.id)

      {:ok, token, _} = Guardian.encode_and_sign(user)
      requester_conn = build_conn() |> put_req_header("authorization", "Bearer #{token}")

      conn =
        post(requester_conn, "/api/upload/#{image.id}/reject-identification", %{
          "rejected_book_ids" => [book.id]
        })

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "returns 404 when image_id is unknown", %{conn: conn} do
      conn =
        post(conn, "/api/upload/#{Ecto.UUID.generate()}/reject-identification", %{
          "rejected_book_ids" => [Ecto.UUID.generate()]
        })

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "returns 422 when no rejected_book_ids resolve to a known book", %{
      conn: conn,
      user: user
    } do
      image = insert(:uploaded_image, status: "resolved", user_id: user.id)

      conn =
        post(conn, "/api/upload/#{image.id}/reject-identification", %{
          "rejected_book_ids" => [Ecto.UUID.generate(), Ecto.UUID.generate()]
        })

      assert %{"error" => "no_resolvable_books"} = json_response(conn, 422)

      refute_enqueued(worker: IdentifyBookJob, args: %{"image_id" => image.id})
    end

    test "enqueues IdentifyBookJob with excluded_isbns resolved from rejected_book_ids",
         %{conn: conn, user: user} do
      author = insert(:author, name: "Orson Scott Card")

      book =
        insert(:book,
          title: "Crystal City",
          author: author,
          editions: [build(:primary_book_edition, isbn: "9781429964500")]
        )

      image = insert(:uploaded_image, status: "resolved", user_id: user.id)

      conn =
        post(conn, "/api/upload/#{image.id}/reject-identification", %{
          "rejected_book_ids" => [book.id]
        })

      assert %{"status" => "pending"} = json_response(conn, 202)

      assert_enqueued(
        worker: IdentifyBookJob,
        args: %{
          "user_id" => user.id,
          "image_id" => image.id,
          "excluded_books" => ["Crystal City by Orson Scott Card"],
          "excluded_isbns" => ["9781429964500"]
        }
      )
    end

    test "deduplicates excluded_isbns when the same book_id appears twice in the rejected list",
         %{conn: conn, user: user} do
      author = insert(:author, name: "A")

      book =
        insert(:book,
          title: "B",
          author: author,
          editions: [build(:primary_book_edition, isbn: "9780743273565")]
        )

      image = insert(:uploaded_image, status: "resolved", user_id: user.id)

      conn =
        post(conn, "/api/upload/#{image.id}/reject-identification", %{
          "rejected_book_ids" => [book.id, book.id]
        })

      assert %{"status" => "pending"} = json_response(conn, 202)

      assert_enqueued(
        worker: IdentifyBookJob,
        args: %{
          "user_id" => user.id,
          "image_id" => image.id,
          "excluded_isbns" => ["9780743273565"]
        }
      )
    end

    test "invalidates poisoned TitleSearchCache entries for ALL edition ISBNs of the rejected book",
         %{conn: conn, user: user} do
      TitleSearchCache.invalidate_all()

      author = insert(:author, name: "Orson Scott Card")

      book =
        insert(:book,
          title: "Crystal City",
          author: author,
          editions: [build(:primary_book_edition, isbn: "9781429964500")]
        )

      insert(:book_edition, book: book, isbn: "9780765341297", is_primary: false)

      image = insert(:uploaded_image, status: "resolved", user_id: user.id)

      :ok =
        TitleSearchCache.put(
          "The Tramp's Crystal City",
          nil,
          nil,
          {:ok, "9781429964500", %{title: "Crystal City"}}
        )

      :ok = TitleSearchCache.put("Crystal City", "Card", nil, {:ok, "9780765341297", %{}})

      :ok = TitleSearchCache.put("Dune", "Herbert", nil, {:ok, "9780441172719", %{}})

      conn =
        post(conn, "/api/upload/#{image.id}/reject-identification", %{
          "rejected_book_ids" => [book.id]
        })

      assert %{"status" => "pending"} = json_response(conn, 202)

      assert :miss = TitleSearchCache.get("The Tramp's Crystal City", nil, nil)
      assert :miss = TitleSearchCache.get("Crystal City", "Card", nil)
      assert {:ok, {:ok, "9780441172719", _}} = TitleSearchCache.get("Dune", "Herbert", nil)
    end
  end

  describe "GET /api/uploads/inbox" do
    test "returns this reader's unfinished uploads, newest first", %{conn: conn, user: user} do
      book = insert(:book)

      insert(:uploaded_image,
        user_id: user.id,
        status: "resolved",
        book_ids: [book.id],
        uploaded_at: ~U[2026-01-01 00:00:00.000000Z]
      )

      failed =
        insert(:uploaded_image,
          user_id: user.id,
          status: "rejected",
          rejection_reason: "vision_unavailable",
          uploaded_at: ~U[2026-06-01 00:00:00.000000Z]
        )

      assert %{"items" => [first, second]} = json_response(get(conn, "/api/uploads/inbox"), 200)

      assert first["image_id"] == failed.id
      assert first["kind"] == "failed"
      assert first["rejection_reason"] == "vision_unavailable"
      assert first["book_ids"] == []

      assert second["kind"] == "awaiting_confirmation"
      assert second["book_ids"] == [book.id]
      assert second["rejection_reason"] == nil
    end

    test "never returns another reader's uploads", %{conn: conn} do
      stranger = insert(:user)
      book = insert(:book)

      insert(:uploaded_image, user_id: stranger.id, status: "resolved", book_ids: [book.id])

      insert(:uploaded_image,
        user_id: stranger.id,
        status: "rejected",
        rejection_reason: "not_a_book"
      )

      assert %{"items" => []} = json_response(get(conn, "/api/uploads/inbox"), 200)
    end

    test "an empty inbox is 200 with an empty list, not a 404", %{conn: conn} do
      assert %{"items" => []} = json_response(get(conn, "/api/uploads/inbox"), 200)
    end

    test "returns 401 without auth token" do
      assert build_conn() |> get("/api/uploads/inbox") |> json_response(401)
    end

    test "reading the inbox places nothing on a bookshelf", %{conn: conn, user: user} do
      book = insert(:book)
      insert(:uploaded_image, user_id: user.id, status: "resolved", book_ids: [book.id])

      assert %{"items" => [%{"kind" => "awaiting_confirmation"}]} =
               json_response(get(conn, "/api/uploads/inbox"), 200)

      refute Stacks.Shelving.book_on_any_shelf?(user.id, book.id)
    end
  end
end
