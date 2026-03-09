defmodule Stacks.BooksTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Books

  describe "create/1" do
    test "creates a book with valid attributes" do
      attrs = %{"isbn" => "9780743273565", "title" => "The Great Gatsby"}
      assert {:ok, book} = Books.create(attrs)
      assert book.isbn == "9780743273565"
      assert book.title == "The Great Gatsby"
    end

    test "returns error on missing isbn" do
      attrs = %{"title" => "No ISBN Book"}
      assert {:error, changeset} = Books.create(attrs)
      assert %{isbn: [_]} = errors_on(changeset)
    end

    test "returns error on duplicate isbn" do
      insert(:book, isbn: "9780743273565")
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
      # 9780743273565 is valid; changing the last digit breaks the checksum
      attrs = %{"isbn" => "9780743273560", "title" => "Bad Checksum"}
      assert {:error, changeset} = Books.create(attrs)
      assert %{isbn: ["has an invalid checksum"]} = errors_on(changeset)
    end

    test "returns error on isbn-10 with invalid checksum" do
      # 0306406152 is a valid ISBN-10; changing the last digit breaks it
      attrs = %{"isbn" => "0306406153", "title" => "Bad ISBN-10 Checksum"}
      assert {:error, changeset} = Books.create(attrs)
      assert %{isbn: ["has an invalid checksum"]} = errors_on(changeset)
    end

    test "accepts isbn-10 with valid checksum" do
      attrs = %{"isbn" => "0306406152", "title" => "Valid ISBN-10"}
      assert {:ok, book} = Books.create(attrs)
      assert book.isbn == "0306406152"
    end
  end

  describe "find_existing/1" do
    test "returns book when isbn exists" do
      book = insert(:book, isbn: "9780743273565")
      assert found = Books.find_existing("9780743273565")
      assert found.id == book.id
    end

    test "returns nil when isbn not found" do
      assert nil == Books.find_existing("9999999999999")
    end
  end

  describe "get_book_detail/1" do
    test "returns book with author preloaded" do
      author = insert(:author)
      book = insert(:book, author: author)
      assert found = Books.get_book_detail(book.id)
      assert found.id == book.id
      assert found.author.id == author.id
    end

    test "returns nil for unknown id" do
      assert nil == Books.get_book_detail(Ecto.UUID.generate())
    end
  end

  describe "search_books/2" do
    test "returns books matching title query" do
      insert(:book, title: "Elixir Programming Guide", isbn: "9780000000001")
      insert(:book, title: "Ruby on Rails Tutorial", isbn: "9780000000002")

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
