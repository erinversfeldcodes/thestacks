defmodule Stacks.BooksTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Books

  describe "create/1" do
    test "creates a book (work) with edition for valid attributes" do
      attrs = %{"isbn" => "9780743273565", "title" => "The Great Gatsby"}
      assert {:ok, book} = Books.create(attrs)
      assert book.title == "The Great Gatsby"
      assert [edition] = book.editions
      assert edition.isbn == "9780743273565"
      assert edition.is_primary == true
    end

    test "returns error on missing isbn" do
      attrs = %{"title" => "No ISBN Book"}
      assert {:error, changeset} = Books.create(attrs)
      assert %{isbn: [_]} = errors_on(changeset)
    end

    test "returns error on duplicate isbn" do
      book = insert(:book)
      insert(:book_edition, book: book, isbn: "9780743273565")
      attrs = %{"isbn" => "9780743273565", "title" => "Duplicate"}
      assert {:error, changeset} = Books.create(attrs)
      assert %{isbn: ["has already been taken"]} = errors_on(changeset)
    end

    test "returns error on invalid isbn format" do
      attrs = %{"isbn" => "not-an-isbn", "title" => "Bad ISBN"}
      assert {:error, changeset} = Books.create(attrs)
      assert %{isbn: [_]} = errors_on(changeset)
    end

    test "returns error on isbn-13 with invalid checksum" do
      attrs = %{"isbn" => "9780743273560", "title" => "Bad Checksum"}
      assert {:error, changeset} = Books.create(attrs)
      assert %{isbn: ["has an invalid checksum"]} = errors_on(changeset)
    end

    test "returns error on isbn-10 with invalid checksum" do
      attrs = %{"isbn" => "0306406153", "title" => "Bad ISBN-10 Checksum"}
      assert {:error, changeset} = Books.create(attrs)
      assert %{isbn: ["has an invalid checksum"]} = errors_on(changeset)
    end

    test "accepts isbn-10 with valid checksum" do
      attrs = %{"isbn" => "0306406152", "title" => "Valid ISBN-10"}
      assert {:ok, book} = Books.create(attrs)
      assert [edition] = book.editions
      assert edition.isbn == "0306406152"
    end
  end

  describe "create/1 — with author" do
    test "creates book and author when author attribute is provided" do
      attrs = %{
        "isbn" => "9780451524935",
        "title" => "Nineteen Eighty-Four",
        "author" => "George Orwell"
      }

      assert {:ok, book} = Books.create(attrs)
      assert [edition] = book.editions
      assert edition.isbn == "9780451524935"
      assert book.author_id != nil
    end

    test "reuses existing author record when author already exists" do
      {:ok, _} =
        Books.create(%{
          "isbn" => "9780141036144",
          "title" => "1984 First Ed",
          "author" => "George Orwell"
        })

      assert {:ok, book2} =
               Books.create(%{
                 "isbn" => "9780451526342",
                 "title" => "Animal Farm",
                 "author" => "George Orwell"
               })

      assert book2.author_id != nil
    end
  end

  describe "find_existing/1" do
    test "returns book when isbn exists" do
      book = insert(:book)
      insert(:book_edition, book: book, isbn: "9780743273565")
      assert found = Books.find_existing("9780743273565")
      assert found.id == book.id
    end

    test "returns nil when isbn not found" do
      assert nil == Books.find_existing("9999999999999")
    end
  end

  describe "get_book_detail/1" do
    test "returns book with author and editions preloaded" do
      author = insert(:author)
      book = insert(:book, author: author)
      insert(:book_edition, book: book)
      assert found = Books.get_book_detail(book.id)
      assert found.id == book.id
      assert found.author.id == author.id
      assert length(found.editions) == 1
    end

    test "returns nil for unknown id" do
      assert nil == Books.get_book_detail(Ecto.UUID.generate())
    end
  end

  describe "primary_edition/1" do
    test "returns the primary edition" do
      book = insert(:book)
      insert(:book_edition, book: book, is_primary: false, isbn: "9780000000001")
      primary = insert(:book_edition, book: book, is_primary: true, isbn: "9780000000002")
      book = Books.get_book_detail(book.id)
      assert Books.primary_edition(book).id == primary.id
    end

    test "falls back to first edition when no primary" do
      book = insert(:book)
      first = insert(:book_edition, book: book, is_primary: false)
      book = Books.get_book_detail(book.id)
      assert Books.primary_edition(book).id == first.id
    end
  end

  describe "search_books/2" do
    test "returns books matching title query" do
      book1 = insert(:book, title: "Elixir Programming Guide")
      insert(:book_edition, book: book1)
      book2 = insert(:book, title: "Ruby on Rails Tutorial")
      insert(:book_edition, book: book2)

      results = Books.search_books("Elixir")
      titles = Enum.map(results, & &1.title)
      assert "Elixir Programming Guide" in titles
      refute "Ruby on Rails Tutorial" in titles
    end

    test "returns empty list when no match" do
      assert [] == Books.search_books("ZZZNoMatchZZZ")
    end
  end
end
