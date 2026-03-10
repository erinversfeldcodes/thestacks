defmodule Stacks.Books.ISBNResolver do
  @moduledoc """
  Resolves ISBNs to book metadata by querying Open Library (primary)
  and Google Books (fallback). Uses Finch for HTTP and Fuse circuit breakers
  for resilience.
  """

  require Logger

  @open_library_url "https://openlibrary.org/api/books"
  @google_books_url "https://www.googleapis.com/books/v1/volumes"

  @open_library_fuse :isbn_resolver_open_library
  @google_books_fuse :isbn_resolver_google_books

  @doc """
  Resolves an ISBN to book metadata. Tries Open Library first, then falls back
  to Google Books. Returns `{:ok, map}` on success, `{:error, :not_found}` otherwise.
  """
  @spec resolve(String.t()) :: {:ok, map()} | {:error, :not_found | :circuit_open}
  def resolve(isbn) do
    case resolve_open_library(isbn) do
      {:ok, data} -> {:ok, data}
      _error -> resolve_google_books(isbn)
    end
  end

  @doc """
  Searches for a book by title and optional author, returning the first match
  with an ISBN. Uses Google Books search API.

  Tries progressively broader queries to handle cut-off titles and partial
  author names:
    1. Full title + full author name
    2. Trimmed title (last word dropped, may be cut off) + full author
    3. Full title + author surname only
    4. Trimmed title + author surname only
    5. Full title only (no author)
    6. Trimmed title only

  Returns `{:ok, isbn, metadata}` on success, `{:error, :not_found}` otherwise.
  """
  @spec search_by_title(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, String.t(), map()} | {:error, :not_found}
  def search_by_title(title, author \\ nil, raw_text \\ nil) do
    trimmed_title = trim_last_word(title)
    surname = author_surname(author)
    raw_keywords = normalize_raw_text(raw_text)

    # Build candidate queries from most to least specific.
    # When raw_text is available, insert enriched queries early — BEFORE broad
    # base candidates — so that keywords like "FDR" disambiguate cut-off or
    # generic titles (e.g. "The Crystal C" + "fdrs" → "Train to Crystal City")
    # before a wider search risks matching the wrong book.
    enriched_prefix =
      if raw_keywords != "" do
        [
          {title <> " " <> raw_keywords, surname},
          {raw_keywords, surname}
        ]
      else
        []
      end

    base_candidates = [
      {title, author},
      {title, surname},
      {trimmed_title, author},
      {trimmed_title, surname}
    ]

    last_resort = [
      {title, nil},
      {trimmed_title, nil},
      {raw_keywords, nil}
    ]

    candidates =
      ([{title, author}] ++ enriched_prefix ++ base_candidates ++ last_resort)
      |> Enum.uniq()
      |> Enum.reject(fn {t, _} -> is_nil(t) or String.trim(t) == "" end)

    Enum.find_value(candidates, {:error, :not_found}, fn {t, a} ->
      case google_books_search(t, a) do
        {:ok, _, _} = result -> result
        _ -> nil
      end
    end)
  end

  # Drop the last whitespace-separated token (handles cut-off words at end of title).
  defp trim_last_word(nil), do: nil

  defp trim_last_word(title) do
    case String.split(String.trim(title), " ") do
      [_single] -> nil
      words -> words |> Enum.drop(-1) |> Enum.join(" ")
    end
  end

  # Extract just the surname (last word) from an author string.
  defp author_surname(nil), do: nil
  defp author_surname(""), do: nil

  defp author_surname(author) do
    author |> String.split() |> List.last()
  end

  # Normalise raw_text from the vision model into a compact keyword string:
  # - Join spaced-out acronyms ("F D R" → "FDR", "U S A" → "USA")
  # - Strip common English stop words and punctuation
  # - Return "" when nothing useful remains
  @stop_words ~w(a an the is are was were it its be been being
                 about of in on at to for with by from and or but
                 not no this that these those we you he she they
                 what who how when where which i me my our)

  defp normalize_raw_text(nil), do: ""
  defp normalize_raw_text(""), do: ""

  defp normalize_raw_text(text) do
    text
    |> String.upcase()
    # Join space-separated single-letter sequences like "F D R" → "FDR".
    # The greedy pattern matches the full run in one pass.
    |> then(fn t ->
      Regex.replace(~r/\b[A-Z]( [A-Z])+/, t, fn match -> String.replace(match, " ", "") end)
    end)
    |> String.downcase()
    # Strip punctuation
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split()
    |> Enum.reject(&(&1 in @stop_words))
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  defp google_books_search(title, author) do
    query =
      if author && author != "" do
        "intitle:#{URI.encode(title)}+inauthor:#{URI.encode(author)}"
      else
        "intitle:#{URI.encode(title)}"
      end

    url = "#{@google_books_url}?q=#{query}&maxResults=1"

    case make_request(url) do
      {:ok, %{"items" => [item | _]}} ->
        info = item["volumeInfo"] || %{}

        isbn =
          (info["industryIdentifiers"] || [])
          |> Enum.find_value(fn
            %{"type" => "ISBN_13", "identifier" => id} -> id
            %{"type" => "ISBN_10", "identifier" => id} -> id
            _ -> nil
          end)

        if isbn do
          authors = info |> Map.get("authors", []) |> Enum.join(", ")

          {:ok, isbn,
           %{
             title: info["title"],
             author: authors,
             description: info["description"],
             cover_image_url: get_in(info, ["imageLinks", "thumbnail"]),
             publisher: info["publisher"],
             publication_year: parse_year(info["publishedDate"]),
             page_count: info["pageCount"],
             subjects: info["categories"] || [],
             google_books_id: item["id"],
             source: :google_books
           }}
        else
          {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp resolve_open_library(isbn) do
    case :fuse.ask(@open_library_fuse, :sync) do
      :ok -> do_open_library_request(isbn)
      :blown -> {:error, :circuit_open}
      # Fuse not yet installed (e.g. test env without full OTP startup)
      {:error, :not_found} -> do_open_library_request(isbn)
    end
  end

  defp do_open_library_request(isbn) do
    url = "#{@open_library_url}?bibkeys=ISBN:#{isbn}&format=json&jscmd=data"

    case make_request(url) do
      {:ok, body} ->
        parse_open_library(body, isbn)

      {:error, reason} ->
        :fuse.melt(@open_library_fuse)
        {:error, reason}
    end
  end

  defp resolve_google_books(isbn) do
    case :fuse.ask(@google_books_fuse, :sync) do
      :ok -> do_google_books_request(isbn)
      :blown -> {:error, :circuit_open}
      # Fuse not yet installed (e.g. test env without full OTP startup)
      {:error, :not_found} -> do_google_books_request(isbn)
    end
  end

  defp do_google_books_request(isbn) do
    url = "#{@google_books_url}?q=isbn:#{isbn}"

    case make_request(url) do
      {:ok, body} ->
        parse_google_books(body)

      {:error, reason} ->
        :fuse.melt(@google_books_fuse)
        {:error, reason}
    end
  end

  defp make_request(url) do
    req = Finch.build(:get, url)

    case Finch.request(req, Stacks.Finch) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        Jason.decode(body)

      {:ok, %Finch.Response{status: status}} ->
        Logger.warning("ISBNResolver: unexpected status #{status} for #{url}")
        {:error, :unexpected_status}

      {:error, reason} ->
        Logger.warning("ISBNResolver: request failed for #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_open_library(data, isbn) when is_map(data) and map_size(data) > 0 do
    key = "ISBN:#{isbn}"

    case Map.get(data, key) do
      nil ->
        {:error, :not_found}

      book_data ->
        authors =
          book_data
          |> Map.get("authors", [])
          |> Enum.map_join(", ", & &1["name"])

        {:ok,
         %{
           title: book_data["title"],
           author: authors,
           description: get_in(book_data, ["excerpts", Access.at(0), "text"]),
           cover_image_url: get_in(book_data, ["cover", "large"]),
           publisher:
             book_data
             |> Map.get("publishers", [])
             |> List.first()
             |> then(&if(is_map(&1), do: &1["name"], else: &1)),
           publication_year: parse_year(book_data["publish_date"]),
           page_count: book_data["number_of_pages"],
           subjects: extract_subjects(book_data["subjects"]),
           open_library_id: book_data["key"],
           source: :open_library
         }}
    end
  end

  defp parse_open_library(_, _), do: {:error, :not_found}

  defp parse_google_books(%{"items" => [item | _]}) do
    info = item["volumeInfo"] || %{}

    authors =
      info
      |> Map.get("authors", [])
      |> Enum.join(", ")

    {:ok,
     %{
       title: info["title"],
       author: authors,
       description: info["description"],
       cover_image_url: get_in(info, ["imageLinks", "thumbnail"]),
       publisher: info["publisher"],
       publication_year: parse_year(info["publishedDate"]),
       page_count: info["pageCount"],
       subjects: info["categories"] || [],
       google_books_id: item["id"],
       source: :google_books
     }}
  end

  defp parse_google_books(_), do: {:error, :not_found}

  defp parse_year(nil), do: nil

  defp parse_year(date_string) when is_binary(date_string) do
    case Integer.parse(String.slice(date_string, 0, 4)) do
      {year, _} -> year
      :error -> nil
    end
  end

  defp extract_subjects(nil), do: []

  defp extract_subjects(subjects) when is_list(subjects) do
    Enum.map(subjects, fn
      subject when is_binary(subject) -> subject
      subject when is_map(subject) -> subject["name"] || ""
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
  end
end
