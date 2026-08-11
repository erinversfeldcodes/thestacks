defmodule Stacks.Imports.GoodreadsCsvTest do
  use ExUnit.Case, async: true

  alias Stacks.Imports.GoodreadsCsv

  @fixture Path.expand("../../support/fixtures/goodreads_library_export.csv", __DIR__)

  describe "parse/1 on the fixture export" do
    setup do
      {:ok, rows} = @fixture |> File.read!() |> GoodreadsCsv.parse()
      %{rows: rows}
    end

    test "reads every data row with a 1-based row number", %{rows: rows} do
      assert length(rows) == 5
      assert Enum.map(rows, & &1.row_number) == [1, 2, 3, 4, 5]
    end

    test "strips the =\"…\" Excel escape from ISBNs", %{rows: [orwell | _]} do
      assert orwell.raw_isbn13 == "9780141036144"
      assert orwell.raw_isbn == "0141036141"
    end

    test "an empty =\"\" ISBN cell becomes an empty string, not a quote pair", %{rows: rows} do
      zine = Enum.at(rows, 4)
      assert zine.raw_isbn == ""
      assert zine.raw_isbn13 == ""
    end

    test "carries the reader's own fields", %{rows: [orwell | _]} do
      assert orwell.raw_title == "1984"
      assert orwell.raw_author == "George Orwell"
      assert orwell.goodreads_shelf == "read"
      assert orwell.raw_rating == 5
      assert orwell.raw_review == "Bleak and necessary."
      assert orwell.raw_notes == "Lent to Sam."
      assert orwell.raw_binding == "Paperback"
      assert orwell.raw_date_read == "2023/06/14"
      assert orwell.raw_date_added == "2023/01/02"
      assert orwell.raw_read_count == 2
      assert orwell.raw_owned_copies == 1
    end
  end

  describe "parse/1 failure modes" do
    test "a file without the Goodreads headers is unrecognised, reporting what it found" do
      assert {:error, :unrecognised_format, headers} =
               GoodreadsCsv.parse("name,isbn\nSome Book,9780141036144\n")

      assert "name" in headers
    end

    test "header-only file has no rows" do
      header = @fixture |> File.read!() |> String.split("\n") |> hd()
      assert {:error, :no_rows} = GoodreadsCsv.parse(header <> "\n")
    end

    test "empty file has no rows" do
      assert {:error, :no_rows} = GoodreadsCsv.parse("")
    end

    test "a row with the wrong column count is kept as unreadable, not dropped" do
      header = @fixture |> File.read!() |> String.split("\n") |> hd()
      {:ok, [row]} = GoodreadsCsv.parse(header <> "\nonly,three,cells\n")

      assert row.outcome == "unreadable"
      assert row.row_number == 1
      assert row.reason =~ "3 columns"
    end

    test "columns are found by header name, not position" do
      csv =
        "ISBN13,Author,Title,Exclusive Shelf\n\"=\"\"9780141036144\"\"\",George Orwell,1984,read\n"

      {:ok, [row]} = GoodreadsCsv.parse(csv)

      assert row.raw_title == "1984"
      assert row.raw_isbn13 == "9780141036144"
      assert row.goodreads_shelf == "read"
    end
  end

  describe "destination_bookshelf/1" do
    test "maps the four US-1.1.9 destinations" do
      assert GoodreadsCsv.destination_bookshelf(%{goodreads_shelf: "read"}) == "library"

      assert GoodreadsCsv.destination_bookshelf(%{goodreads_shelf: "currently-reading"}) ==
               "reading_pile"

      assert GoodreadsCsv.destination_bookshelf(%{
               goodreads_shelf: "to-read",
               raw_owned_copies: 1
             }) == "antilibrary"

      assert GoodreadsCsv.destination_bookshelf(%{
               goodreads_shelf: "to-read",
               raw_owned_copies: 0
             }) == "wishlist"
    end

    test "an unrecognised shelf maps to nothing" do
      assert GoodreadsCsv.destination_bookshelf(%{goodreads_shelf: "abandoned-forever"}) == nil
    end
  end

  describe "format_for/1" do
    test "maps Goodreads bindings onto the platform vocabulary" do
      assert GoodreadsCsv.format_for("Paperback") == "paperback"
      assert GoodreadsCsv.format_for("Hardcover") == "hardcover"
      assert GoodreadsCsv.format_for("Kindle Edition") == "ebook"
      assert GoodreadsCsv.format_for("Audio CD") == "audiobook"
      assert GoodreadsCsv.format_for("Board book") == nil
      assert GoodreadsCsv.format_for("") == nil
    end
  end
end
