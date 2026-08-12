defmodule Stacks.Imports.GoodreadsCsv do
  @moduledoc """
      Parses `goodreads_library_export.csv` into `op.library_import_rows`
      attrs. Two Goodreads facts live here and nowhere else: the `="…"` Excel
      escape around ISBNs (unwrapped at parse time — the naive parse fails the
      hard gate on every row), and header-addressed columns (Goodreads has
      reordered its export before; a file missing `Title`/`Author`/`ISBN13`
      is rejected as `unrecognised_format` at upload time, not minutes later
      as a failed job).
  """

  alias NimbleCSV.RFC4180, as: CSV

  @required_headers ["Title", "Author", "ISBN13"]

  @doc """
      Parses the CSV binary. Returns `{:ok, rows}` (attr maps ready for insert,
      1-based `row_number`s, unreadable rows pre-marked) or
      `{:error,:unrecognised_format, found_headers}` / `{:error,:no_rows}`.
  """
  @spec parse(binary()) ::
          {:ok, [map()]}
          | {:error, :unrecognised_format, [String.t()]}
          | {:error, :no_rows}
  def parse(binary) do
    case CSV.parse_string(binary, skip_headers: false) do
      [] ->
        {:error, :no_rows}

      [headers | data_rows] ->
        headers = Enum.map(headers, &String.trim/1)

        cond do
          not Enum.all?(@required_headers, &(&1 in headers)) ->
            {:error, :unrecognised_format, headers}

          data_rows == [] ->
            {:error, :no_rows}

          true ->
            index = headers |> Enum.with_index() |> Map.new()

            {:ok,
             data_rows |> Enum.with_index(1) |> Enum.map(&parse_row(&1, index, length(headers)))}
        end
    end
  rescue
    _ in NimbleCSV.ParseError -> {:error, :unrecognised_format, []}
  end

  defp parse_row({cells, row_number}, index, expected_width) do
    if length(cells) == expected_width do
      at = fn header -> cell(cells, index, header) end

      %{
        row_number: row_number,
        raw_title: at.("Title"),
        raw_author: at.("Author"),
        raw_isbn: unwrap_isbn(at.("ISBN")),
        raw_isbn13: unwrap_isbn(at.("ISBN13")),
        goodreads_shelf: at.("Exclusive Shelf"),
        raw_rating: int(at.("My Rating")),
        raw_review: at.("My Review"),
        raw_notes: at.("Private Notes"),
        raw_binding: at.("Binding"),
        raw_date_read: at.("Date Read"),
        raw_date_added: at.("Date Added"),
        raw_read_count: int(at.("Read Count")),
        raw_owned_copies: int(at.("Owned Copies"))
      }
    else
      %{
        row_number: row_number,
        outcome: "unreadable",
        reason:
          "row #{row_number} has #{length(cells)} columns where the header has #{expected_width}"
      }
    end
  end

  defp cell(cells, index, header) do
    case Map.fetch(index, header) do
      {:ok, position} -> cells |> Enum.at(position, "") |> to_string() |> String.trim()
      :error -> ""
    end
  end

  @doc """
      Strips Goodreads' `="…"` wrapper and surrounding quotes from an ISBN cell.
  """
  @spec unwrap_isbn(String.t() | nil) :: String.t()
  def unwrap_isbn(nil), do: ""

  def unwrap_isbn(value) do
    value
    |> String.trim()
    |> String.replace_prefix("=", "")
    |> String.trim("\"")
    |> String.trim()
  end

  defp int(value) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n
      :error -> 0
    end
  end

  @doc """
      The destination bookshelf for a row (mapping): Goodreads' own
      owned-copies flag is what tells the antilibrary from the wishlist.
  """
  @spec destination_bookshelf(map()) :: String.t() | nil
  def destination_bookshelf(%{goodreads_shelf: shelf} = row) do
    case shelf do
      "read" -> "library"
      "currently-reading" -> "reading_pile"
      "to-read" -> if Map.get(row, :raw_owned_copies, 0) >= 1, do: "antilibrary", else: "wishlist"
      _ -> nil
    end
  end

  @doc """
      Goodreads bindings mapped onto the platform's format vocabulary; anything
      unrecognised is left off rather than guessed.
  """
  @spec format_for(String.t()) :: String.t() | nil
  def format_for(binding) do
    case String.downcase(to_string(binding)) do
      "paperback" -> "paperback"
      "hardcover" -> "hardcover"
      "kindle edition" -> "ebook"
      "ebook" -> "ebook"
      "audiobook" -> "audiobook"
      "audio cd" -> "audiobook"
      _ -> nil
    end
  end
end
