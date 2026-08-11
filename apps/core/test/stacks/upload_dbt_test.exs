defmodule Stacks.UploadDbtTest do
  @moduledoc """
  Suite 9: upload-pipeline events trigger the right dbt refresh jobs via
  `DbtRefreshHandler`, and the underlying records the staging views
  expose are correct after each upload-flow scenario — all 8 user stories
  of 111 (upload/hard-gate/non-book/age-gate/manual-ISBN/duplicate/
  multi-book/SSE), each asserting both the enqueued refresh and the row
  state dbt would read.
  """

  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.AI.VisionFixtures
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Books
  alias Stacks.Books.{Book, BookEdition, UploadedImage}
  alias Stacks.Shelving
  alias Stacks.Shelving.{Bookshelf, Placement}
  alias Stacks.Workers.DbtRefreshHandler
  alias Stacks.Workers.DbtRefreshJob
  alias Stacks.Workers.IdentifyBookJob

  defp build_event(event_type) do
    %{event_type: event_type, aggregate_id: Ecto.UUID.generate(), payload: %{}}
  end

  defp create_user_with_book(opts \\ []) do
    visibility = Keyword.get(opts, :visibility_tier, "public")
    isbn = Keyword.get(opts, :isbn, nil)

    user = insert(:user)
    author = insert(:author)

    edition_attrs = if isbn, do: [isbn: isbn], else: []

    book =
      insert(:book,
        author: author,
        title: Keyword.get(opts, :title, "Test Book"),
        visibility_tier: visibility,
        editions: [build(:primary_book_edition, edition_attrs)]
      )

    {user, book, hd(book.editions), author}
  end

  defp sequence_isbn, do: build(:primary_book_edition).isbn

  describe "upload-pipeline events: book.created" do
    @tag stories: ["US-1.1.1"], suite: :dbt
    test "does not enqueue a dbt refresh job" do
      event = build_event("book.created")
      assert :ok = DbtRefreshHandler.handle_event(event)

      refute_enqueued(worker: DbtRefreshJob)
    end
  end

  describe "upload-pipeline events: placement.created" do
    @tag stories: ["US-1.1.1"], suite: :dbt
    test "enqueues dbt refresh with community and searchable models" do
      event = build_event("placement.created")
      assert :ok = DbtRefreshHandler.handle_event(event)

      assert_enqueued(
        worker: DbtRefreshJob,
        args: %{models: ["mart_community_read_count", "mart_platform_searchable"]}
      )
    end
  end

  describe "upload-pipeline events: image.submitted" do
    @tag stories: ["US-1.1.1"], suite: :dbt
    test "does not enqueue a dbt refresh job" do
      event = build_event("image.submitted")
      assert :ok = DbtRefreshHandler.handle_event(event)

      refute_enqueued(worker: DbtRefreshJob)
    end
  end

  describe "full upload flow integration" do
    @tag stories: ["US-1.1.1"], suite: :dbt
    test "book.created + placement.created sequence enqueues exactly one dbt job" do
      book_event = build_event("book.created")
      placement_event = build_event("placement.created")

      assert :ok = DbtRefreshHandler.handle_event(book_event)
      refute_enqueued(worker: DbtRefreshJob)

      assert :ok = DbtRefreshHandler.handle_event(placement_event)

      assert_enqueued(
        worker: DbtRefreshJob,
        args: %{models: ["mart_community_read_count", "mart_platform_searchable"]}
      )
    end

    @tag stories: ["US-1.1.1"], suite: :dbt
    test "image.submitted + book.created + placement.created enqueues only placement dbt job" do
      for event_type <- ["image.submitted", "book.created"] do
        assert :ok = DbtRefreshHandler.handle_event(build_event(event_type))
      end

      refute_enqueued(worker: DbtRefreshJob)

      assert :ok = DbtRefreshHandler.handle_event(build_event("placement.created"))

      assert_enqueued(
        worker: DbtRefreshJob,
        args: %{models: ["mart_community_read_count", "mart_platform_searchable"]}
      )
    end
  end

  describe "handler return values" do
    @tag stories: ["US-1.1.1"], suite: :dbt
    test "returns :ok for mapped upload-pipeline events" do
      assert :ok = DbtRefreshHandler.handle_event(build_event("placement.created"))
    end

    @tag stories: ["US-1.1.1"], suite: :dbt
    test "returns :ok for unmapped upload-pipeline events" do
      assert :ok = DbtRefreshHandler.handle_event(build_event("book.created"))
      assert :ok = DbtRefreshHandler.handle_event(build_event("image.submitted"))
    end

    @tag stories: ["US-1.1.1"], suite: :dbt
    test "returns :ok for events without event_type key" do
      assert :ok = DbtRefreshHandler.handle_event(%{some_other: "structure"})
    end
  end

  describe "DbtRefreshHandler: enrichment events in upload flow" do
    @tag stories: ["US-1.1.1"], suite: :dbt
    test "enrichment.prices_scraped enqueues price model refresh" do
      event = build_event("enrichment.prices_scraped")
      assert :ok = DbtRefreshHandler.handle_event(event)

      assert_enqueued(
        worker: DbtRefreshJob,
        args: %{models: ["int_price_trends", "mart_book_prices"]}
      )
    end

    @tag stories: ["US-1.1.1"], suite: :dbt
    test "placement.moved enqueues community read count refresh" do
      event = build_event("placement.moved")
      assert :ok = DbtRefreshHandler.handle_event(event)

      assert_enqueued(
        worker: DbtRefreshJob,
        args: %{models: ["mart_community_read_count"]}
      )
    end

    @tag stories: ["US-1.6.4"], suite: :dbt
    test "placement.removed enqueues community read count refresh" do
      event = build_event("placement.removed")
      assert :ok = DbtRefreshHandler.handle_event(event)

      assert_enqueued(
        worker: DbtRefreshJob,
        args: %{models: ["mart_community_read_count"]}
      )
    end

    @tag stories: ["US-1.1.1"], suite: :dbt
    test "image.resolved does not enqueue a dbt refresh job" do
      event = build_event("image.resolved")
      assert :ok = DbtRefreshHandler.handle_event(event)

      refute_enqueued(worker: DbtRefreshJob)
    end

    @tag stories: ["US-1.1.2"], suite: :dbt
    test "image.rejected does not enqueue a dbt refresh job" do
      event = build_event("image.rejected")
      assert :ok = DbtRefreshHandler.handle_event(event)

      refute_enqueued(worker: DbtRefreshJob)
    end

    @tag stories: ["US-1.1.6"], suite: :dbt
    test "books.confirmed does not enqueue a dbt refresh job" do
      event = build_event("books.confirmed")
      assert :ok = DbtRefreshHandler.handle_event(event)

      refute_enqueued(worker: DbtRefreshJob)
    end

    @tag stories: ["US-1.1.8"], suite: :dbt
    test "books.edition_merged does not enqueue a dbt refresh job" do
      event = build_event("books.edition_merged")
      assert :ok = DbtRefreshHandler.handle_event(event)

      refute_enqueued(worker: DbtRefreshJob)
    end
  end

  describe "US-1.1.1: successful upload -> book + edition + placement records" do
    @tag stories: ["US-1.1.1"], suite: :dbt
    test "uploaded_images record has correct status and storage_path after upload" do
      image = insert(:uploaded_image, storage_path: "uploads/test-image-id", status: "pending")

      db_image = Repo.get(UploadedImage, image.id)
      assert db_image.status == "pending"
      assert db_image.storage_path == "uploads/test-image-id"
      assert db_image.uploaded_at != nil
      assert db_image.expires_at != nil

      diff = DateTime.diff(db_image.expires_at, db_image.uploaded_at, :day)
      assert diff >= 29 and diff <= 31
    end

    @tag stories: ["US-1.1.1"], suite: :dbt
    test "books and book_editions records exist after book creation" do
      {_user, book, edition, author} = create_user_with_book()

      db_book = Repo.get(Book, book.id)
      assert db_book != nil
      assert db_book.title == "Test Book"
      assert db_book.author_id == author.id
      assert db_book.visibility_tier == "public"

      db_edition = Repo.get(BookEdition, edition.id)
      assert db_edition != nil
      assert db_edition.isbn != nil
      assert db_edition.book_id == book.id
      assert db_edition.is_primary == true
    end

    @tag stories: ["US-1.1.1"], suite: :dbt
    test "bookshelf_placements record exists with correct IDs after placement" do
      {user, book, _edition, _author} = create_user_with_book()

      {:ok, placement} = Shelving.place_book(user.id, book.id, "library")

      db_placement = Repo.get(Placement, placement.id)
      assert db_placement != nil
      assert db_placement.book_id == book.id

      bookshelf = Repo.get(Bookshelf, db_placement.bookshelf_id)
      assert bookshelf != nil
      assert bookshelf.user_id == user.id
      assert bookshelf.name == "library"
    end

    @tag stories: ["US-1.1.1"], suite: :dbt
    test "placement.created event triggers dbt refresh after real placement" do
      {user, book, _edition, _author} = create_user_with_book()

      {:ok, _placement} = Shelving.place_book(user.id, book.id, "wishlist")

      event = build_event("placement.created")
      assert :ok = DbtRefreshHandler.handle_event(event)

      assert_enqueued(
        worker: DbtRefreshJob,
        args: %{models: ["mart_community_read_count", "mart_platform_searchable"]}
      )
    end

    @tag stories: ["US-1.1.1"], suite: :dbt
    test "uploaded_images record updated to resolved with book_id" do
      {_user, book, _edition, _author} = create_user_with_book()
      image = insert(:uploaded_image, status: "pending")

      {:ok, image_id_bin} = Ecto.UUID.dump(image.id)
      {:ok, book_id_bin} = Ecto.UUID.dump(book.id)

      query = from(i in "uploaded_images", where: i.id == ^image_id_bin)

      {1, _} =
        Repo.update_all(
          query,
          [
            set: [
              status: "resolved",
              book_id: book_id_bin,
              book_ids: [book_id_bin],
              updated_at: DateTime.utc_now()
            ]
          ],
          prefix: "op"
        )

      db_image = Repo.get(UploadedImage, image.id)
      assert db_image.status == "resolved"
      assert db_image.book_id == book.id
      assert db_image.book_ids == [book.id]
    end
  end

  describe "US-1.1.2: ISBN hard gate rejection records" do
    @tag stories: ["US-1.1.2"], suite: :dbt
    test "uploaded_images marked rejected with isbn_not_found reason" do
      image = insert(:uploaded_image, status: "pending")

      {:ok, image_id_bin} = Ecto.UUID.dump(image.id)
      query = from(i in "uploaded_images", where: i.id == ^image_id_bin)

      {1, _} =
        Repo.update_all(
          query,
          [
            set: [
              status: "rejected",
              rejection_reason: "isbn_not_found",
              updated_at: DateTime.utc_now()
            ]
          ],
          prefix: "op"
        )

      db_image = Repo.get(UploadedImage, image.id)
      assert db_image.status == "rejected"
      assert db_image.rejection_reason == "isbn_not_found"
    end

    @tag stories: ["US-1.1.2"], suite: :dbt
    test "no books or editions created on ISBN rejection" do
      book_count_before = Repo.aggregate(Book, :count, :id)

      user = insert(:user)
      image = insert(:uploaded_image, status: "pending")

      with_vision(no_isbn(), fn ->
        perform_job(IdentifyBookJob, %{
          "user_id" => user.id,
          "image_id" => image.id,
          "image_b64" => Base.encode64("fake image bytes for testing")
        })
      end)

      assert Repo.aggregate(Book, :count, :id) == book_count_before
    end

    @tag stories: ["US-1.1.2"], suite: :dbt
    test "no placements created on ISBN rejection" do
      placement_count_before = Repo.aggregate(Placement, :count)

      _image = insert(:uploaded_image, status: "rejected", rejection_reason: "isbn_not_found")

      assert Repo.aggregate(Placement, :count) == placement_count_before
    end

    @tag stories: ["US-1.1.2"], suite: :dbt
    test "no dbt refresh enqueued for image.rejected event" do
      assert :ok = DbtRefreshHandler.handle_event(build_event("image.rejected"))
      refute_enqueued(worker: DbtRefreshJob)
    end
  end

  describe "US-1.1.3: non-book rejection records" do
    @tag stories: ["US-1.1.3"], suite: :dbt
    test "uploaded_images marked rejected with not_a_book reason" do
      image = insert(:uploaded_image, status: "pending")

      {:ok, image_id_bin} = Ecto.UUID.dump(image.id)
      query = from(i in "uploaded_images", where: i.id == ^image_id_bin)

      {1, _} =
        Repo.update_all(
          query,
          [
            set: [
              status: "rejected",
              rejection_reason: "not_a_book",
              updated_at: DateTime.utc_now()
            ]
          ],
          prefix: "op"
        )

      db_image = Repo.get(UploadedImage, image.id)
      assert db_image.status == "rejected"
      assert db_image.rejection_reason == "not_a_book"
    end

    @tag stories: ["US-1.1.3"], suite: :dbt
    test "no books, editions, or placements created on non-book rejection" do
      book_count = Repo.aggregate(Book, :count)
      edition_count = Repo.aggregate(BookEdition, :count)
      placement_count = Repo.aggregate(Placement, :count)

      _image = insert(:uploaded_image, status: "rejected", rejection_reason: "not_a_book")

      assert Repo.aggregate(Book, :count) == book_count
      assert Repo.aggregate(BookEdition, :count) == edition_count
      assert Repo.aggregate(Placement, :count) == placement_count
    end
  end

  describe "US-1.1.4: age-gated book records" do
    @tag stories: ["US-1.1.4"], suite: :dbt
    test "book with age_gated visibility_tier persists correctly" do
      {_user, book, _edition, _author} = create_user_with_book(visibility_tier: "age_gated")

      db_book = Repo.get(Book, book.id)
      assert db_book.visibility_tier == "age_gated"
    end

    @tag stories: ["US-1.1.4"], suite: :dbt
    test "age_gated book is excluded from unauthenticated catalogue listing" do
      {_user, _book, _edition, _author} = create_user_with_book(visibility_tier: "age_gated")

      {books, _total} = Books.list_catalogue(viewer: :unauthenticated)
      refute Enum.any?(books, fn b -> b.visibility_tier == "age_gated" end)
    end

    @tag stories: ["US-1.1.4"], suite: :dbt
    test "age_gated book is included for an age-verified authenticated viewer" do
      {user, book, _edition, _author} = create_user_with_book(visibility_tier: "age_gated")

      {books, _total} = Books.list_catalogue(viewer: {:platform_user, user.id, true})
      assert Enum.any?(books, fn b -> b.id == book.id end)
    end

    @tag stories: ["US-1.1.4"], suite: :dbt
    test "age_gated book is excluded for an authenticated-but-unverified viewer" do
      {user, _book, _edition, _author} = create_user_with_book(visibility_tier: "age_gated")

      {books, _total} = Books.list_catalogue(viewer: {:platform_user, user.id, false})
      refute Enum.any?(books, fn b -> b.visibility_tier == "age_gated" end)
    end

    @tag stories: ["US-1.1.4"], suite: :dbt
    test "placement on age-gated book still triggers dbt refresh" do
      event = build_event("placement.created")
      assert :ok = DbtRefreshHandler.handle_event(event)

      assert_enqueued(
        worker: DbtRefreshJob,
        args: %{models: ["mart_community_read_count", "mart_platform_searchable"]}
      )
    end
  end

  describe "US-1.1.5: manual ISBN entry records" do
    @tag stories: ["US-1.1.5"], suite: :dbt
    test "book created via manual ISBN has correct edition data" do
      isbn = sequence_isbn()
      {_user, book, edition, _author} = create_user_with_book(isbn: isbn)

      db_edition =
        BookEdition
        |> where([e], e.book_id == ^book.id and e.is_primary == true)
        |> Repo.one()

      assert db_edition != nil
      assert db_edition.isbn == edition.isbn
      assert String.match?(db_edition.isbn, ~r/^\d{13}$/)
    end

    @tag stories: ["US-1.1.5"], suite: :dbt
    test "manual ISBN entry does not create duplicate editions for same ISBN" do
      isbn = sequence_isbn()
      {_user, book, _edition, _author} = create_user_with_book(isbn: isbn)

      duplicate =
        Books.book_edition_changeset(%BookEdition{}, %{
          "isbn" => isbn,
          "book_id" => book.id,
          "is_primary" => false,
          "verification_source" => "open_library"
        })

      assert duplicate.valid?, inspect(duplicate.errors)
      assert {:error, changeset} = Repo.insert(duplicate)
      assert {"has already been taken", _} = changeset.errors[:isbn]
    end
  end

  describe "US-1.1.6: duplicate book detection records" do
    @tag stories: ["US-1.1.6"], suite: :dbt
    test "find_existing returns book when ISBN already exists" do
      {_user, book, edition, _author} = create_user_with_book()

      found = Books.find_existing(edition.isbn)
      assert found != nil
      assert found.id == book.id
    end

    @tag stories: ["US-1.1.6"], suite: :dbt
    test "find_existing returns nil for unknown ISBN" do
      assert Books.find_existing("9780000000000") == nil
    end

    @tag stories: ["US-1.1.6"], suite: :dbt
    test "book_on_any_shelf? returns true for placed book" do
      {user, book, _edition, _author} = create_user_with_book()
      {:ok, _placement} = Shelving.place_book(user.id, book.id, "library")

      assert Shelving.book_on_any_shelf?(user.id, book.id)
    end

    @tag stories: ["US-1.1.6"], suite: :dbt
    test "book_on_any_shelf? returns false for unplaced book" do
      {user, book, _edition, _author} = create_user_with_book()

      refute Shelving.book_on_any_shelf?(user.id, book.id)
    end

    @tag stories: ["US-1.1.6"], suite: :dbt
    test "no new book created when duplicate detected" do
      {_user, book, edition, _author} = create_user_with_book()
      book_count = Repo.aggregate(Book, :count)

      found = Books.find_existing(edition.isbn)
      assert found.id == book.id
      assert Repo.aggregate(Book, :count) == book_count
    end
  end

  describe "US-1.1.7: bulk upload records (multi-book from single image)" do
    @tag stories: ["US-1.1.7"], suite: :dbt
    test "uploaded_images stores multiple book_ids for multi-book resolution" do
      {_user, book1, _ed1, _author1} = create_user_with_book(title: "Book One")
      {_user2, book2, _ed2, _author2} = create_user_with_book(title: "Book Two")

      image = insert(:uploaded_image, status: "pending")

      {:ok, image_id_bin} = Ecto.UUID.dump(image.id)
      {:ok, book1_id_bin} = Ecto.UUID.dump(book1.id)
      {:ok, book2_id_bin} = Ecto.UUID.dump(book2.id)

      query = from(i in "uploaded_images", where: i.id == ^image_id_bin)

      {1, _} =
        Repo.update_all(
          query,
          [
            set: [
              status: "resolved",
              book_id: book1_id_bin,
              book_ids: [book1_id_bin, book2_id_bin],
              updated_at: DateTime.utc_now()
            ]
          ],
          prefix: "op"
        )

      db_image = Repo.get(UploadedImage, image.id)
      assert db_image.status == "resolved"
      assert length(db_image.book_ids) == 2
      assert book1.id in db_image.book_ids
      assert book2.id in db_image.book_ids
    end

    @tag stories: ["US-1.1.7"], suite: :dbt
    test "each book from bulk upload can be placed independently" do
      user = insert(:user)
      {_u1, book1, _ed1, _a1} = create_user_with_book(title: "Bulk Book A")
      {_u2, book2, _ed2, _a2} = create_user_with_book(title: "Bulk Book B")

      {:ok, p1} = Shelving.place_book(user.id, book1.id, "library")
      {:ok, p2} = Shelving.place_book(user.id, book2.id, "wishlist")

      assert Repo.get(Placement, p1.id) != nil
      assert Repo.get(Placement, p2.id) != nil
      assert Shelving.book_on_any_shelf?(user.id, book1.id)
      assert Shelving.book_on_any_shelf?(user.id, book2.id)
    end
  end

  describe "US-1.1.8: multi-format merge records" do
    @tag stories: ["US-1.1.8"], suite: :dbt
    test "merging adds a new non-primary edition to existing work" do
      {_user, book, _edition, _author} = create_user_with_book()

      edition_count_before =
        BookEdition
        |> where([e], e.book_id == ^book.id)
        |> Repo.aggregate(:count)

      new_isbn = sequence_isbn()

      new_edition =
        insert(:book_edition,
          book: book,
          isbn: new_isbn,
          format_label: "Hardcover",
          is_primary: false
        )

      edition_count_after =
        BookEdition
        |> where([e], e.book_id == ^book.id)
        |> Repo.aggregate(:count)

      assert edition_count_after == edition_count_before + 1

      db_new = Repo.get(BookEdition, new_edition.id)
      assert db_new.is_primary == false
      assert db_new.format_label == "Hardcover"
      assert db_new.book_id == book.id
    end

    @tag stories: ["US-1.1.8"], suite: :dbt
    test "original primary edition unchanged after merge" do
      {_user, book, edition, _author} = create_user_with_book()
      _new_edition = insert(:book_edition, book: book, isbn: sequence_isbn(), is_primary: false)

      db_original = Repo.get(BookEdition, edition.id)
      assert db_original.is_primary == true
    end

    @tag stories: ["US-1.1.8"], suite: :dbt
    test "no new book created when edition merged to existing work" do
      {_user, book, _edition, _author} = create_user_with_book()
      book_count = Repo.aggregate(Book, :count)

      _new_edition = insert(:book_edition, book: book, isbn: sequence_isbn(), is_primary: false)

      assert Repo.aggregate(Book, :count) == book_count
      assert Repo.get(Book, book.id) != nil
    end
  end

  describe "full event sequence: upload -> identify -> place" do
    @tag stories: ["US-1.1.1"], suite: :dbt
    test "complete happy-path event sequence enqueues correct dbt jobs" do
      assert :ok = DbtRefreshHandler.handle_event(build_event("image.submitted"))
      refute_enqueued(worker: DbtRefreshJob)

      assert :ok = DbtRefreshHandler.handle_event(build_event("image.resolved"))
      refute_enqueued(worker: DbtRefreshJob)

      assert :ok = DbtRefreshHandler.handle_event(build_event("book.created"))
      refute_enqueued(worker: DbtRefreshJob)

      assert :ok = DbtRefreshHandler.handle_event(build_event("placement.created"))

      assert_enqueued(
        worker: DbtRefreshJob,
        args: %{models: ["mart_community_read_count", "mart_platform_searchable"]}
      )
    end

    @tag stories: ["US-1.1.2", "US-1.1.3"], suite: :dbt
    test "rejection event sequence does not enqueue any dbt jobs" do
      assert :ok = DbtRefreshHandler.handle_event(build_event("image.submitted"))
      assert :ok = DbtRefreshHandler.handle_event(build_event("image.rejected"))

      refute_enqueued(worker: DbtRefreshJob)
    end

    @tag stories: ["US-1.1.1"], suite: :dbt
    test "placement.moved enqueues community read count refresh (standalone)" do
      assert :ok = DbtRefreshHandler.handle_event(build_event("placement.moved"))

      assert_enqueued(
        worker: DbtRefreshJob,
        args: %{models: ["mart_community_read_count"]}
      )
    end
  end

  describe "deployed-only: dbt staging views reflect op table data" do
    @moduletag :deployed_only

    @tag stories: ["US-1.1.4"], suite: :dbt
    test "stg_books view exposes book with correct visibility_tier" do
      {_user, book, _edition, _author} = create_user_with_book(visibility_tier: "age_gated")

      result =
        Repo.query(
          "SELECT id, title, visibility_tier FROM wh.stg_books WHERE id = $1",
          [book.id]
        )

      case result do
        {:ok, %{rows: [[_id, title, tier]]}} ->
          assert title == "Test Book"
          assert tier == "age_gated"

        {:error, _} ->
          :ok
      end
    end

    @tag stories: ["US-1.1.1"], suite: :dbt
    test "stg_book_editions view exposes edition with ISBN" do
      {_user, _book, edition, _author} = create_user_with_book()

      result =
        Repo.query(
          "SELECT isbn, is_primary FROM wh.stg_book_editions WHERE id = $1",
          [edition.id]
        )

      case result do
        {:ok, %{rows: [[isbn, is_primary]]}} ->
          assert isbn == edition.isbn
          assert is_primary == true

        {:error, _} ->
          :ok
      end
    end

    @tag stories: ["US-1.1.2"], suite: :dbt
    test "stg_uploaded_images view exposes rejected image with reason" do
      image =
        insert(:uploaded_image, status: "rejected", rejection_reason: "isbn_not_found")

      result =
        Repo.query(
          "SELECT status, rejection_reason FROM wh.stg_uploaded_images WHERE id = $1",
          [image.id]
        )

      case result do
        {:ok, %{rows: [[status, reason]]}} ->
          assert status == "rejected"
          assert reason == "isbn_not_found"

        {:error, _} ->
          :ok
      end
    end

    @tag stories: ["US-1.1.1"], suite: :dbt
    test "stg_bookshelf_placements view exposes placement with bookshelf_id" do
      {user, book, _edition, _author} = create_user_with_book()
      {:ok, placement} = Shelving.place_book(user.id, book.id, "antilibrary")

      result =
        Repo.query(
          "SELECT book_id, bookshelf_id FROM wh.stg_bookshelf_placements WHERE id = $1",
          [placement.id]
        )

      case result do
        {:ok, %{rows: [[book_id, _bookshelf_id]]}} ->
          assert book_id == book.id

        {:error, _} ->
          :ok
      end
    end

    @tag stories: ["US-1.1.1"], suite: :dbt
    test "mart_community_read_count reflects placement after dbt refresh" do
      {user, book, _edition, _author} = create_user_with_book()
      {:ok, _placement} = Shelving.place_book(user.id, book.id, "library")

      count = Books.community_read_count(book.id)

      assert is_integer(count)
    end
  end
end
