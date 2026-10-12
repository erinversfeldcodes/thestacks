defmodule Stacks.FactoryHonestyTest do
  @moduledoc """
      — the factory may only build states production can produce.

      Each test here is an *impossibility probe*: it takes the invalid state the
      factory used to hand out for free and shows that the factory no longer
      reaches it. These are the guard rails for `test/support/factory.ex`; if one
      fails, a factory has started manufacturing rows no write path can create and
      every test downstream of it is asserting on fiction.
  """
  use Core.DataCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts.User
  alias Stacks.Books
  alias Stacks.Books.Book
  alias Stacks.Books.BookEdition
  alias Stacks.Books.ISBN
  alias Stacks.Books.UploadedImage
  alias Stacks.Shelving
  alias Stacks.Shelving.{Placement, Shelf}

  describe "probe 1 — a work always has its primary edition (ISBN hard gate)" do
    test "insert(:book) produces a work whose primary_edition is not nil" do
      book = insert(:book)

      assert %BookEdition{} = edition = Books.primary_edition(book)
      assert edition.book_id == book.id
      assert edition.is_primary
    end

    test "the editionless state is only reachable through the explicitly-named factory" do
      book = insert(:editionless_book)

      assert Books.primary_edition(book) == nil
      assert Repo.aggregate(from(e in BookEdition, where: e.book_id == ^book.id), :count) == 0
    end
  end

  describe "probe 2 — every factory ISBN passes production's checksum validation" do
    test "1000 consecutive factory ISBNs are all checksum-valid and unique" do
      isbns = for _ <- 1..1000, do: build(:book_edition).isbn

      refute Enum.any?(isbns, &(!ISBN.valid_isbn_checksum?(&1)))
      assert length(Enum.uniq(isbns)) == 1000
      assert Enum.all?(isbns, &(String.length(&1) == 13))
    end

    test "a factory-built edition survives the production changeset it used to fail" do
      edition = build(:book_edition)

      changeset =
        Books.book_edition_changeset(%BookEdition{}, %{
          "isbn" => edition.isbn,
          "book_id" => insert(:book).id,
          "verification_source" => edition.verification_source
        })

      assert changeset.valid?, inspect(changeset.errors)
    end

    test "a work never ends up with two primary editions" do
      book = insert(:book)
      insert(:book_edition, book: book)
      insert(:book_edition, book: book)

      primaries =
        Repo.all(from(e in BookEdition, where: e.book_id == ^book.id and e.is_primary == true))

      assert length(primaries) == 1
    end
  end

  describe "probe 3 — a placement's shelf belongs to the placement's bookshelf" do
    test "insert(:placement) keeps shelf.bookshelf_id == placement.bookshelf_id" do
      placement = insert(:placement)
      shelf = Repo.get!(Shelf, placement.shelf_id)

      assert shelf.bookshelf_id == placement.bookshelf_id
    end

    test "a bare placement creates exactly one bookshelf, owned by one user" do
      placement = insert(:placement)

      bookshelf_ids =
        Repo.all(
          from(s in Shelf,
            join: p in Placement,
            on: p.shelf_id == s.id,
            where: p.id == ^placement.id,
            select: s.bookshelf_id
          )
        )

      assert bookshelf_ids == [placement.bookshelf_id]
    end

    test "overriding the bookshelf re-homes the shelf with it" do
      bookshelf = insert(:bookshelf)
      placement = insert(:placement, bookshelf: bookshelf)
      shelf = Repo.get!(Shelf, placement.shelf_id)

      assert placement.bookshelf_id == bookshelf.id
      assert shelf.bookshelf_id == bookshelf.id
    end
  end

  describe "one relationship, one row" do
    test "a price snapshot's book is its edition's book, and only one work exists" do
      before = Repo.aggregate(Stacks.Books.Book, :count)
      snapshot = insert(:price_snapshot)

      assert Repo.aggregate(Stacks.Books.Book, :count) - before == 1
      assert snapshot.book_id == snapshot.book_edition.book_id
    end

    test "a transaction's seller is its listing's seller, and only one user exists" do
      transaction = Repo.preload(insert(:transaction), :listing)

      assert transaction.seller_id == transaction.listing.seller_id
      refute transaction.seller_id == transaction.buyer_id
    end
  end

  describe "probe 4 — a confirmed user traversed confirmation" do
    test "insert(:user) has no dangling confirmation token" do
      user = insert(:user)

      assert user.email_confirmed
      assert user.email_confirmation_token == nil
    end

    test "insert(:user) can log in, which the unconfirmed state forbids" do
      user = insert(:user)

      assert {:ok, _} = Stacks.Accounts.authenticate(user.email, "password123")
    end

    test "the unconfirmed state stays reachable and still holds its token" do
      user = insert(:unconfirmed_user)

      refute user.email_confirmed
      assert is_binary(user.email_confirmation_token)

      assert {:error, :email_unconfirmed} =
               Stacks.Accounts.authenticate(user.email, "password123")
    end

    test "the unconfirmed factory produces exactly what register/1 produces" do
      {:ok, registered} =
        Stacks.Accounts.register(%{
          "email" => "probe-register@example.com",
          "password" => "password123",
          "display_name" => "Probe",
          "handle" => "probe_register"
        })

      factory_built = insert(:unconfirmed_user)

      assert registered.email_confirmed == factory_built.email_confirmed
      assert is_binary(registered.email_confirmation_token)
      assert is_binary(factory_built.email_confirmation_token)
    end
  end

  describe "probe 5 — a placement's reading dates match the status it carries" do
    test "the reading pile holds books being read, and a book being read was started" do
      placement = insert(:placement, bookshelf: build(:bookshelf, name: "reading_pile"))

      assert placement.reading_status == "reading"
      assert placement.started_at
      refute placement.finished_at
    end

    test "the library holds books that were finished, and a finished book has a finish date" do
      placement = insert(:placement, bookshelf: build(:bookshelf, name: "library"))

      assert placement.reading_status == "completed"
      assert placement.finished_at
    end

    test "a wishlist book has not been started" do
      placement = insert(:placement, bookshelf: build(:bookshelf, name: "wishlist"))

      assert placement.reading_status == "to_read"
      refute placement.started_at
      refute placement.finished_at
    end

    test "no bookshelf and status pairing reaches a date the write path would have stamped" do
      for name <- Shelving.bookshelf_names(),
          status <- ~w(to_read reading completed abandoned) do
        placement =
          insert(:placement,
            bookshelf: build(:bookshelf, name: name),
            reading_status: status
          )

        context = "#{status} on #{name}"

        if status == "reading", do: assert(placement.started_at, "started_at nil for #{context}")

        if status == "completed",
          do: assert(placement.finished_at, "finished_at nil for #{context}")

        if status == "to_read" do
          refute placement.started_at, "started_at set for #{context}"
          refute placement.finished_at, "finished_at set for #{context}"
        end
      end
    end

    test "a pinned date is the one that survives" do
      pinned = ~U[2026-01-02 03:04:05.000000Z]

      placement = insert(:placement, reading_status: "reading", started_at: pinned)

      assert placement.started_at == pinned
    end

    test "the derived state is one update_reading_progress/3 would accept unchanged" do
      bookshelf = insert(:bookshelf, name: "reading_pile")
      placement = insert(:placement, bookshelf: bookshelf)

      assert {:ok, unchanged} =
               Shelving.update_reading_progress(placement.id, bookshelf.user_id, %{
                 "reading_status" => placement.reading_status
               })

      assert unchanged.started_at == placement.started_at
    end
  end

  describe "probe 6 — a bookshelf is one bookshelf_changeset/2 would accept" do
    test "a name outside the five is unreachable without even reaching the enum" do
      assert_raise ArgumentError, ~r/no write path/, fn -> build(:bookshelf, name: "kitchen") end
    end

    test "a visibility off the audience ladder is unreachable the same way" do
      assert_raise ArgumentError, ~r/no write path/, fn ->
        build(:bookshelf, visibility: "everyone")
      end
    end

    test "a user with the whole set owns exactly the five named bookshelves" do
      user = insert_user_with_bookshelves()

      names = user.id |> Shelving.list_user_bookshelves() |> Enum.map(& &1.name)

      assert Enum.sort(names) == Enum.sort(Shelving.bookshelf_names())
      assert Enum.all?(names, &Shelving.get_bookshelf(user.id, &1))
    end
  end

  describe "probe 7 — an uploaded image has an uploader and a stored object" do
    test "insert(:uploaded_image) is reachable from the account that uploaded it" do
      image = insert(:uploaded_image)

      assert image.user_id
      assert Repo.get_by(UploadedImage, id: image.id, user_id: image.user_id)
    end

    test "the storage key is the one store_upload/2 would have derived from the row" do
      image = insert(:uploaded_image)

      assert image.storage_path == "uploads/#{image.id}"
    end

    test "naming the owner attaches to that account rather than inventing another" do
      user = insert(:user)
      before = Repo.aggregate(User, :count)

      image = insert(:uploaded_image, user_id: user.id)

      assert image.user_id == user.id
      assert Repo.aggregate(User, :count) == before
    end

    test "the ownerless state stays reachable through the factory that names it" do
      image = insert(:orphaned_uploaded_image)

      assert image.user_id == nil
    end
  end

  describe "probe 8 — an edition belongs to the work it was given" do
    test "attaching to a work by struct does not mint a second one" do
      book = insert(:book)
      before = Repo.aggregate(Book, :count)

      edition = insert(:book_edition, book: book)

      assert edition.book_id == book.id
      assert Repo.aggregate(Book, :count) == before
    end

    test "attaching to a work by id does not mint a second one" do
      book = insert(:book)
      before = Repo.aggregate(Book, :count)

      edition = insert(:book_edition, book_id: book.id)

      assert edition.book_id == book.id
      assert Repo.aggregate(Book, :count) == before
    end

    test "a work's only edition is its primary edition" do
      book = insert(:editionless_book)

      edition = insert(:book_edition, book: book)

      assert edition.is_primary
      assert Books.primary_edition(Repo.preload(book, :editions)).id == edition.id
    end

    test "an edition on a work that already has a primary is a secondary one" do
      book = insert(:book)

      refute insert(:book_edition, book: book).is_primary
    end
  end
end
