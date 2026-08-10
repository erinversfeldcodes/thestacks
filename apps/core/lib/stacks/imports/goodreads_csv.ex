defmodule Stacks.Imports.GoodreadsCsv do
  @moduledoc """
  Parses `goodreads_library_export.csv` (US-1.1.9) into row attrs for
  `op.library_import_rows`.

  Two Goodreads-specific facts live here and nowhere else:

    * **The `="…"` Excel escape.** Goodreads wraps ISBNs as `="0439023483"` so
      spreadsheets keep the leading zero. The naive parse yields a 13-character
      string that is not an ISBN, every row fails the hard gate, and the whole
      import reports unverified — so the unwrap happens at parse time, before
      anything downstream sees the value.
    * **Header-addressed columns.** Goodreads has reordered its export before;
      positional parsing would silently shift every field. Columns are read by
      header name, and a file missing the three load-bearing headers (`Title`,
      `Author`, `ISBN13`) is rejected as `unrecognised_format` — answered at
      upload time, not minutes later as a failed job.

  A row that cannot be read (wrong column count, quoting broken mid-row) is
  kept as `outcome: "unreadable"` with its row number, so the reader can find
  it in their own file. The parser never drops a row silently.
  """

  alias NimbleCSV.RFC4180, as: CSV

  @required_headers ["Title", "Author", "ISBN13"]

  @doc """
  Parses the CSV binary. Returns `{:ok, rows}` (attr maps ready for insert,
  1-based `row_number`s, unreadable rows pre-marked) or
  `{:error, :unrecognised_format, found_headers}` / `{:error, :no_rows}`.
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
    # NimbleCSV raises on quoting broken beyond recovery — a file-level parse
    # failure, reported as format rather than a crash.
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
  The destination bookshelf for a row (US-1.1.9's mapping): Goodreads' own
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
