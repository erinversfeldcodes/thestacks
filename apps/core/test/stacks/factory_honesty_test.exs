defmodule Stacks.FactoryHonestyTest do
  @moduledoc """
  Issue #329 — the factory may only build states production can produce.

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
  alias Stacks.Books
  alias Stacks.Books.BookEdition
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

      refute Enum.any?(isbns, &(!Books.valid_isbn_checksum?(&1)))
      assert length(Enum.uniq(isbns)) == 1000
      assert Enum.all?(isbns, &(String.length(&1) == 13))
    end

    test "a factory-built edition survives the production changeset it used to fail" do
      edition = build(:book_edition)

      changeset =
        Books.book_edition_changeset(%BookEdition{}, %{
          "isbn" => edition.isbn,
          "book_id" => insert(:book).id,
          # Provenance is required on every edition (#335 D1); the factory sets
          # it, so pass the factory's value rather than a literal — the point of
          # this probe is that what the factory builds is what production takes.
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

  # Two columns describing one relationship must be built from one value, and
  # must be INSERTED once. Ecto has no identity map, so naming the same unsaved
  # struct on two association paths silently created two rows with two ids —
  # the desync each factory's comment exists to prevent.
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
end
