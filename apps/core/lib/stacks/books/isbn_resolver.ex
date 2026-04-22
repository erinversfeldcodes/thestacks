defmodule Stacks.Books.ISBNResolver do
  @moduledoc """
  Resolves ISBNs to book metadata by querying Open Library (primary)
  and Google Books (fallback). Uses Finch for HTTP and Fuse circuit breakers
  for resilience.
  """

  require Logger

  alias Stacks.Books.ISBNResolverCache
  alias Stacks.Books.TitleSearchCache

  @open_library_url "https://openlibrary.org/api/books"
  @open_library_search_url "https://openlibrary.org/search.json"
  @google_books_url "https://www.googleapis.com/books/v1/volumes"

  # Hard deadline for the parallel OL + GB race. Each individual upstream
  # has its own HTTP client timeout, but this cap protects the upload job
  # from a truly stuck external service.
  @race_timeout_ms 5_000

  defp google_books_api_key do
    Application.get_env(:core, :google_books_api_key)
  end

  defp google_books_url(params) do
    base = "#{@google_books_url}?#{params}"

    case google_books_api_key() do
      nil -> base
      key -> "#{base}&key=#{key}"
    end
  end

  @open_library_fuse :open_library_fuse
  @google_books_fuse :google_books_fuse

  @doc """
  Resolves an ISBN to book metadata.

  Flow:
    1. Check `ISBNResolverCache` — immutable ISBN→book means we cache
       positive results for 24h, negative for 1h.
    2. On miss, race OpenLibrary and Google Books in parallel and take
       the first success. Costs one extra API call per request when OL
       hits first, but cuts ~300ms off the worst case (sequential
       fallback was `OL_time + GB_time`; parallel is `max(OL, GB)`).
    3. Memoise the result (positive or negative).

  Circuit-open responses are NOT cached — the fuse is the signal to
  retry later, not to memoise.
  """
  @spec resolve(String.t()) :: {:ok, map()} | {:error, :not_found | :circuit_open}
  def resolve(isbn) do
    if cache_enabled?() do
      case ISBNResolverCache.get(isbn) do
        {:ok, cached} ->
          cached

        :miss ->
          result = race_resolve(isbn)
          ISBNResolverCache.put(isbn, result)
          result
      end
    else
      race_resolve(isbn)
    end
  end

  # ETS is global, so per-test mocks leaking across tests via the cache
  # would make the resolver suite flaky. `config/test.exs` disables
  # caching; prod/dev leave it on (default true).
  defp cache_enabled? do
    Application.get_env(:core, :isbn_resolver_cache_enabled, true)
  end

  # Race OL and GB in parallel. First `{:ok, _}` wins; remaining tasks
  # are killed. If both fail, return the last error seen (or
  # `{:error, :not_found}` on timeout).
  defp race_resolve(isbn) do
    ol = Task.async(fn -> resolve_open_library(isbn) end)
    gb = Task.async(fn -> resolve_google_books(isbn) end)
    await_first_success([ol, gb], {:error, :not_found})
  end

  defp await_first_success([], last_error), do: last_error

  defp await_first_success(tasks, last_error) do
    receive do
      {ref, result} when is_reference(ref) ->
        case Enum.find(tasks, &(&1.ref == ref)) do
          nil ->
            # Stale ref from a prior call — ignore and keep waiting.
            await_first_success(tasks, last_error)

          _task ->
            # Flush any pending :DOWN for this finished task.
            Process.demonitor(ref, [:flush])
            others = Enum.reject(tasks, &(&1.ref == ref))

            case result do
              {:ok, _} = ok ->
                Enum.each(others, &Task.shutdown(&1, :brutal_kill))
                ok

              err ->
                await_first_success(others, err)
            end
        end

      {:DOWN, ref, :process, _pid, _reason} ->
        # Task crashed without sending a result. Drop it and keep waiting.
        remaining = Enum.reject(tasks, &(&1.ref == ref))
        await_first_success(remaining, last_error)
    after
      @race_timeout_ms ->
        Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
        last_error
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

  Results are cached in `TitleSearchCache` keyed by `(title, author,
  raw_text)` with 24h positive / 1h negative TTL. Repeat lookups for
  the same extracted title (common on probe workloads and real users
  uploading the same book cover or text post multiple times) skip
  OL/GB entirely.
  """
  @spec search_by_title(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, String.t(), map()} | {:error, :not_found}
  def search_by_title(title, author \\ nil, raw_text \\ nil) do
    if title_cache_enabled?() do
      case TitleSearchCache.get(title, author, raw_text) do
        {:ok, cached} ->
          cached

        :miss ->
          result = do_search_by_title(title, author, raw_text)
          TitleSearchCache.put(title, author, raw_text, result)
          result
      end
    else
      do_search_by_title(title, author, raw_text)
    end
  end

  defp title_cache_enabled? do
    Application.get_env(:core, :title_search_cache_enabled, true)
  end

  defp do_search_by_title(title, author, raw_text) do
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

    # Strip subtitle (text after : or —) for books with long titles like
    # "Born Again Bodies: Flesh and Spirit in American Christianity" → "Born Again Bodies"
    main_title = strip_subtitle(title)

    base_candidates = [
      {title, author},
      {title, surname},
      {trimmed_title, author},
      {trimmed_title, surname}
    ]

    subtitle_candidates =
      if main_title do
        [{main_title, author}, {main_title, surname}, {main_title, nil}]
      else
        []
      end

    last_resort = [
      {title, nil},
      {trimmed_title, nil},
      {raw_keywords, nil}
    ]

    candidates =
      ([{title, author}] ++
         enriched_prefix ++ base_candidates ++ subtitle_candidates ++ last_resort)
      |> Enum.uniq()
      |> Enum.reject(fn {t, _} -> is_nil(t) or String.trim(t) == "" end)

    Enum.find_value(candidates, {:error, :not_found}, &try_candidate/1)
  end

  # Race OL + GB per candidate query. The `resolve/1` path already does
  # this for direct-ISBN lookups; title-based candidates benefit even
  # more because `search_by_title/3` can try up to 12 candidate variants,
  # so sequential OL-then-GB inside each one compounds to 24+ HTTP
  # round-trips on a miss. Racing halves per-candidate cost and, for
  # mixed_text uploads (which may resolve several books), meaningfully
  # reduces total pipeline time.
  #
  # The existing `await_first_success/2` helper matches `{:ok, _}` —
  # OL/GB title searches return a 3-tuple `{:ok, isbn, metadata}`, so
  # wrap+unwrap around the race rather than duplicate the helper.
  defp try_candidate({t, a}) do
    ol = Task.async(fn -> wrap_3tuple(open_library_title_search(t, a)) end)
    gb = Task.async(fn -> wrap_3tuple(google_books_search(t, a)) end)

    case await_first_success([ol, gb], {:error, :not_found}) do
      {:ok, {isbn, metadata}} -> {:ok, isbn, metadata}
      _ -> nil
    end
  end

  defp wrap_3tuple({:ok, isbn, metadata}), do: {:ok, {isbn, metadata}}
  defp wrap_3tuple(other), do: other

  # Strip subtitle after `:`, `–`, or `—` (handles long academic titles like
  # "Born Again Bodies: Flesh and Spirit in American Christianity" → "Born Again Bodies").
  defp strip_subtitle(nil), do: nil

  defp strip_subtitle(title) do
    case Regex.split(~r/\s*[:–—]\s*/, title, parts: 2) do
      [main, _] ->
        stripped = String.trim(main)
        if stripped == "" or stripped == title, do: nil, else: stripped

      _ ->
        nil
    end
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

  # Search Open Library by title + optional author.
  # Returns {isbn, metadata} with partial metadata from the search result,
  # so store_book can skip the secondary ISBN lookup (which often fails for
  # obscure editions). Prefers ISBN-13 over ISBN-10.
  defp open_library_title_search(title, author) do
    case :fuse.ask(@open_library_fuse, :sync) do
      :blown -> {:error, :circuit_open}
      :ok -> do_open_library_title_search(title, author)
    end
  end

  defp do_open_library_title_search(title, author) do
    base = [
      {"title", title},
      {"fields", "key,title,isbn,author_name,subject,first_publish_year"},
      {"limit", "5"}
    ]

    params = if author && author != "", do: base ++ [{"author", author}], else: base
    url = "#{@open_library_search_url}?#{URI.encode_query(params)}"

    case make_request(url) do
      {:ok, %{"docs" => docs}} when is_list(docs) ->
        Enum.find_value(docs, {:error, :not_found}, &build_ol_metadata/1)

      {:error, _} ->
        Stacks.CircuitBreakers.melt(@open_library_fuse)
        {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  defp build_ol_metadata(doc) do
    isbns = Map.get(doc, "isbn", [])

    isbn =
      Enum.find(isbns, &(String.length(&1) == 13)) ||
        Enum.find(isbns, &(String.length(&1) == 10))

    if isbn do
      author_str = doc |> Map.get("author_name", []) |> Enum.join(", ")

      {:ok, isbn,
       %{
         title: doc["title"],
         author: if(author_str != "", do: author_str, else: nil),
         subjects: doc |> Map.get("subject", []) |> Enum.take(5),
         publication_year: doc["first_publish_year"],
         source: :open_library
       }}
    else
      nil
    end
  end

  defp google_books_search(title, author) do
    case :fuse.ask(@google_books_fuse, :sync) do
      :blown -> {:error, :circuit_open}
      :ok -> do_google_books_search(title, author)
    end
  end

  defp do_google_books_search(title, author) do
    query =
      if author && author != "" do
        "intitle:#{URI.encode(title)}+inauthor:#{URI.encode(author)}"
      else
        "intitle:#{URI.encode(title)}"
      end

    url = google_books_url("q=#{query}&maxResults=1")

    case make_request(url) do
      {:ok, %{"items" => [item | _]}} ->
        parse_google_books_search_item(item)

      {:error, _} ->
        Stacks.CircuitBreakers.melt(@google_books_fuse)
        {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  defp parse_google_books_search_item(item) do
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
  end

  defp resolve_open_library(isbn) do
    case :fuse.ask(@open_library_fuse, :sync) do
      :ok -> do_open_library_request(isbn)
      :blown -> {:error, :circuit_open}
    end
  end

  defp do_open_library_request(isbn) do
    url = "#{@open_library_url}?bibkeys=ISBN:#{isbn}&format=json&jscmd=data"

    case make_request(url) do
      {:ok, body} ->
        parse_open_library(body, isbn)

      {:error, reason} ->
        Stacks.CircuitBreakers.melt(@open_library_fuse)
        {:error, reason}
    end
  end

  defp resolve_google_books(isbn) do
    case :fuse.ask(@google_books_fuse, :sync) do
      :ok -> do_google_books_request(isbn)
      :blown -> {:error, :circuit_open}
    end
  end

  defp do_google_books_request(isbn) do
    url = google_books_url("q=isbn:#{isbn}")

    case make_request(url) do
      {:ok, body} ->
        parse_google_books(body)

      {:error, reason} ->
        Stacks.CircuitBreakers.melt(@google_books_fuse)
        {:error, reason}
    end
  end

  defp make_request(url) do
    Application.get_env(:core, :isbn_http_client, Stacks.Books.HttpClient).get(url)
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

        ol_key = book_data["key"]

        work_key =
          Map.get(book_data, "works", [])
          |> List.first()
          |> then(fn
            %{"key" => k} -> k
            _ -> nil
          end)

        open_library_work_id =
          cond do
            is_binary(work_key) ->
              work_key |> String.split("/") |> List.last()

            is_binary(ol_key) and String.contains?(ol_key, "/works/") ->
              ol_key |> String.split("/") |> List.last()

            true ->
              nil
          end

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
           open_library_id: ol_key,
           open_library_work_id: open_library_work_id,
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
