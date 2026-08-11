defmodule Stacks.Books.ISBNResolver do
  @moduledoc """
  Resolves ISBNs to book metadata by querying Open Library (primary)
  and Google Books (fallback). Uses Finch for HTTP and Fuse circuit breakers
  for resilience.
  """

  require Logger

  alias Stacks.Books.CandidateScorer
  alias Stacks.Books.HttpClientBehaviour
  alias Stacks.Books.ISBN
  alias Stacks.Books.ISBNResolverCache
  alias Stacks.Books.TitleSearchCache

  @typedoc """
  Closed set of error reasons returned by `resolve/1`. Extends the
  underlying `HttpClientBehaviour.error_reason()` with two resolver-level
  reasons: `:not_found` (no upstream returned a match) and
  `:circuit_open` (the relevant Fuse breaker is blown). Adding a new
  reason here requires adding a matching clause in
  `Stacks.Workers.EnrichBookJob.outcome_tag/1` and in `determination/1` —
  both are written without a catch-all, so dialyzer enforces the
  exhaustiveness end-to-end.
  """
  @type error_reason ::
          HttpClientBehaviour.error_reason()
          | :not_found
          | :circuit_open

  @doc """
  Whether a failure said something about the *ISBN* or about *us*.

  This is the question every caller of `resolve/1` actually has, and until #344
  none of them asked it: they matched `{:error, _}` and recorded the answer as a
  property of the book. So a Google Books 503 — our dependency being down — was
  written down as `:invalid_book` on the moderation funnel and answered to the
  reader as `isbn_not_found`, i.e. "this is not a real book". It is not a
  statement about the book at all; nobody looked.

  Exactly one reason is a conclusion:

    * `:not_found` — both upstreams answered, and neither knows this ISBN.
      That IS a property of the ISBN, and recording it as one is correct.

  The rest are statements about the lookup, which did not happen: a blown fuse,
  a 5xx, a body we could not parse, a dead socket, a timeout. Repeating the
  request may well produce a different answer, and nothing has been learned
  about the book in the meantime.

  Written without a catch-all on purpose, and mirroring
  `Stacks.AI.VisionError.determination/1`, which splits vision failures on the
  same axis: a new `error_reason/0` must be classified here before it can ship,
  rather than defaulting into "the book's fault", which is the failure mode this
  function exists to end.
  """
  @spec determination(error_reason()) :: :not_found | :unavailable
  def determination(:not_found), do: :not_found
  def determination(:circuit_open), do: :unavailable
  def determination(:unexpected_status), do: :unavailable
  def determination(:malformed_response), do: :unavailable
  def determination(:transport_error), do: :unavailable
  def determination(:timeout), do: :unavailable

  @doc """
  True when `reason` is a member of `error_reason/0`.

  Callers that receive failures from more than one source — `Stacks.Books.confirm/2`
  hands back changesets and `Stacks.Shelving` errors alongside resolver ones — use
  this to decide whether `determination/1` applies, instead of assuming it does
  and being met with a `FunctionClauseError`. Mirrors
  `Stacks.AI.VisionError.vision_error?/1`.
  """
  @spec resolver_error?(term()) :: boolean()
  def resolver_error?(reason)
      when reason in [
             :not_found,
             :circuit_open,
             :unexpected_status,
             :malformed_response,
             :transport_error,
             :timeout
           ],
      do: true

  def resolver_error?(_other), do: false

  @open_library_url "https://openlibrary.org/api/books"
  @open_library_search_url "https://openlibrary.org/search.json"
  @open_library_works_url "https://openlibrary.org/works"
  @google_books_url "https://www.googleapis.com/books/v1/volumes"

  @max_editions_per_work 50

  @race_timeout_ms 8_000

  defp google_books_api_key do
    Application.get_env(:core, :google_books_api_key)
  end

  @doc false
  @spec google_books_url(String.t()) :: String.t()
  def google_books_url(params) do
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
  @spec resolve(String.t()) :: {:ok, map()} | {:error, error_reason()}
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

  defp cache_enabled? do
    Application.get_env(:core, :isbn_resolver_cache_enabled, true)
  end

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
            await_first_success(tasks, last_error)

          _task ->
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
  with an ISBN. Consults Open Library first and falls back to Google Books
  only when Open Library misses for a given query variant (see
  `try_candidate/4` for the rationale).

  Tries progressively broader queries to handle cut-off titles and partial
  author names:
    1. Full title + full author name
    2. Trimmed title (last word dropped, may be cut off) + full author
    3. Full title + author surname only
    4. Trimmed title + author surname only
    5. Full title only (no author)
    6. Trimmed title only

  Returns `{:ok, isbn, metadata}` on success. On failure it answers the
  question `determination/1` asks of the direct-lookup path, because the title
  path has exactly the same two things to say (#352):

    * `{:error, :not_found}` — every query variant was answered by both
      catalogues, and none of them knew this book. A fact about the book.
    * `{:error, :unavailable}` — at least one lookup never happened: a blown
      fuse, a 5xx, an undecodable body, a dead socket, a timeout. A fact about
      us. Nothing has been learned about the book, and retrying may well
      produce a different answer.

  Until #352 both arrived as `{:error, :not_found}`, so a provider outage was
  reported to the reader as "there is no such book" — and then, being
  indistinguishable from a real miss, was written into the negative cache and
  repeated for an hour after the providers came back.

  Results are cached in `TitleSearchCache` keyed by `(title, author,
  raw_text)` with 24h positive / 1h negative TTL. Repeat lookups for
  the same extracted title (common on probe workloads and real users
  uploading the same book cover or text post multiple times) skip
  OL/GB entirely. **`:unavailable` is never cached** — see the cache
  policy note on `TitleSearchCache.put/4`.

  ## Options

    * `:excluded_isbns` — list of ISBN strings to skip when matching OL/GB
      search results. Used by the rejection-retry flow: the user has
      already said "no" to a book whose ISBN we resolved, so any OL/GB
      hit that maps to that same ISBN is suppressed and we fall through
      to the next candidate query variant. Comparison is hyphen/space-
      insensitive (so `"978-0-12-345678-9"` matches `"9780123456789"`).

  ## Cache behaviour

  When `excluded_isbns` is non-empty, the `TitleSearchCache` is bypassed
  entirely. A cached entry was computed without the exclusion list and
  would return the very ISBN the caller asked us to skip. Bypassing
  rather than keying-with-exclusions keeps the cache table compact —
  retry requests are rare relative to first-attempt requests, so the
  extra OL/GB call on a retry is an acceptable trade for not exploding
  the cache key space.
  """
  @spec search_by_title(String.t(), String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, String.t(), map()} | {:error, :not_found | :unavailable}
  def search_by_title(title, author \\ nil, raw_text \\ nil, opts \\ []) do
    excluded_isbns = Keyword.get(opts, :excluded_isbns, [])
    excluded_descriptors = Keyword.get(opts, :excluded_book_descriptors, [])

    if excluded_isbns != [] or excluded_descriptors != [] do
      Logger.info(
        "ISBNResolver.search_by_title: title=#{inspect(title)} excluded_isbns=#{inspect(excluded_isbns)} excluded_descriptors=#{inspect(excluded_descriptors)}"
      )
    end

    cond do
      excluded_isbns != [] or excluded_descriptors != [] ->
        do_search_by_title(title, author, raw_text, excluded_isbns, excluded_descriptors)

      title_cache_enabled?() ->
        case TitleSearchCache.get(title, author, raw_text) do
          {:ok, cached} ->
            cached

          :miss ->
            result = do_search_by_title(title, author, raw_text, [], [])
            TitleSearchCache.put(title, author, raw_text, result)
            result
        end

      true ->
        do_search_by_title(title, author, raw_text, [], [])
    end
  end

  defp title_cache_enabled? do
    Application.get_env(:core, :title_search_cache_enabled, true)
  end

  defp do_search_by_title(title, author, raw_text, excluded_isbns, excluded_descriptors) do
    trimmed_title = trim_last_word(title)
    surname = author_surname(author)
    raw_keywords = normalize_raw_text(raw_text)

    signals = %{title: title, author: author, raw_text: raw_text}

    enriched_prefix =
      if raw_keywords != "" do
        [
          {title <> " " <> raw_keywords, surname},
          {raw_keywords, surname}
        ]
      else
        []
      end

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

    candidates
    |> Enum.reduce_while(:not_found, fn candidate, determination ->
      case try_candidate(candidate, signals, excluded_isbns, excluded_descriptors) do
        {:ok, _isbn, _metadata} = hit -> {:halt, hit}
        :not_found -> {:cont, determination}
        :unavailable -> {:cont, :unavailable}
      end
    end)
    |> search_result()
  end

  defp search_result({:ok, _isbn, _metadata} = hit), do: hit

  defp search_result(:not_found), do: {:error, :not_found}

  defp search_result(:unavailable), do: {:error, :unavailable}

  defp try_candidate({t, a}, signals, excluded_isbns, excluded_descriptors) do
    case open_library_title_search(t, a, signals, excluded_isbns, excluded_descriptors) do
      {:ok, isbn, metadata} ->
        accept_or_exclude(isbn, metadata, excluded_isbns, excluded_descriptors, :not_found)

      {:error, ol_reason} ->
        case google_books_search(t, a, signals, excluded_isbns, excluded_descriptors) do
          {:ok, isbn, metadata} ->
            accept_or_exclude(
              isbn,
              metadata,
              excluded_isbns,
              excluded_descriptors,
              determination(ol_reason)
            )

          {:error, gb_reason} ->
            worse_of(determination(ol_reason), determination(gb_reason))
        end
    end
  end

  defp accept_or_exclude(isbn, metadata, excluded_isbns, excluded_descriptors, on_excluded) do
    cond do
      excluded_isbn?(isbn, excluded_isbns) -> on_excluded
      excluded_descriptor?(metadata, excluded_descriptors) -> on_excluded
      true -> {:ok, isbn, metadata}
    end
  end

  defp worse_of(:unavailable, _other), do: :unavailable
  defp worse_of(_one, :unavailable), do: :unavailable
  defp worse_of(:not_found, :not_found), do: :not_found

  defp excluded_isbn?(_isbn, []), do: false

  defp excluded_isbn?(isbn, excluded_isbns) do
    normalised = normalise_isbn_for_compare(isbn)

    normalised != "" and
      Enum.any?(excluded_isbns, &(normalise_isbn_for_compare(&1) == normalised))
  end

  defp normalise_isbn_for_compare(value) when is_binary(value),
    do: ISBN.canonical_isbn13(value)

  defp normalise_isbn_for_compare(_), do: ""

  defp excluded_descriptor?(_metadata, []), do: false

  defp excluded_descriptor?(metadata, excluded_descriptors) do
    case metadata_descriptor(metadata) do
      "" ->
        false

      descriptor ->
        normalised = normalise_descriptor_for_compare(descriptor)

        Enum.any?(
          excluded_descriptors,
          &(normalise_descriptor_for_compare(&1) == normalised)
        )
    end
  end

  defp metadata_descriptor(%{title: title, author: author})
       when is_binary(title) and title != "" do
    case author do
      bin when is_binary(bin) and bin != "" -> "#{title} by #{bin}"
      _ -> title
    end
  end

  defp metadata_descriptor(_), do: ""

  defp normalise_descriptor_for_compare(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^[:alnum:]\s]/u, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalise_descriptor_for_compare(_), do: ""

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

  defp trim_last_word(nil), do: nil

  defp trim_last_word(title) do
    case String.split(String.trim(title), " ") do
      [_single] -> nil
      words -> words |> Enum.drop(-1) |> Enum.join(" ")
    end
  end

  defp author_surname(nil), do: nil
  defp author_surname(""), do: nil

  defp author_surname(author) do
    author |> String.split() |> List.last()
  end

  @stop_words ~w(a an the is are was were it its be been being
                 about of in on at to for with by from and or but
                 not no this that these those we you he she they
                 what who how when where which i me my our)

  defp normalize_raw_text(nil), do: ""
  defp normalize_raw_text(""), do: ""

  defp normalize_raw_text(text) do
    text
    |> String.replace(~r/['’]/u, "")
    |> String.upcase()
    |> then(fn t ->
      Regex.replace(~r/\b[A-Z]( [A-Z])+/, t, fn match -> String.replace(match, " ", "") end)
    end)
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split()
    |> Enum.reject(&(&1 in @stop_words))
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  defp open_library_title_search(title, author, signals, excluded_isbns, excluded_descriptors) do
    case :fuse.ask(@open_library_fuse, :sync) do
      :blown ->
        {:error, :circuit_open}

      :ok ->
        do_open_library_title_search(title, author, signals, excluded_isbns, excluded_descriptors)
    end
  end

  defp do_open_library_title_search(title, author, signals, excluded_isbns, excluded_descriptors) do
    base = [
      {"title", title},
      {"fields", "key,title,subtitle,isbn,author_name,subject,first_publish_year"},
      {"limit", "5"}
    ]

    params = if author && author != "", do: base ++ [{"author", author}], else: base
    url = "#{@open_library_search_url}?#{URI.encode_query(params)}"

    case make_request(url) do
      {:ok, %{"docs" => docs}} when is_list(docs) ->
        docs
        |> Enum.map(&build_ol_metadata(&1, excluded_isbns, excluded_descriptors))
        |> Enum.reject(&is_nil/1)
        |> pick_best_candidate(:open_library, signals)

      {:error, reason} ->
        Stacks.CircuitBreakers.melt(@open_library_fuse)
        {:error, reason}

      _ ->
        {:error, :not_found}
    end
  end

  defp build_ol_metadata(doc, excluded_isbns, excluded_descriptors) do
    isbns = Map.get(doc, "isbn", [])

    isbn =
      Enum.find(isbns, &(String.length(&1) == 13)) ||
        Enum.find(isbns, &(String.length(&1) == 10))

    if isbn do
      author_str = doc |> Map.get("author_name", []) |> Enum.join(", ")

      metadata = %{
        title: doc["title"],
        subtitle: doc["subtitle"],
        author: if(author_str != "", do: author_str, else: nil),
        subjects: doc |> Map.get("subject", []) |> Enum.take(5),
        publication_year: doc["first_publish_year"],
        source: :open_library
      }

      apply_ol_exclusion(:open_library, isbn, metadata, excluded_isbns, excluded_descriptors)
    else
      nil
    end
  end

  defp google_books_search(title, author, signals, excluded_isbns, excluded_descriptors) do
    case :fuse.ask(@google_books_fuse, :sync) do
      :blown ->
        {:error, :circuit_open}

      :ok ->
        do_google_books_search(title, author, signals, excluded_isbns, excluded_descriptors)
    end
  end

  defp do_google_books_search(title, author, signals, excluded_isbns, excluded_descriptors) do
    query =
      if author && author != "" do
        "intitle:#{URI.encode(title)}+inauthor:#{URI.encode(author)}"
      else
        "intitle:#{URI.encode(title)}"
      end

    url = google_books_url("q=#{query}&maxResults=5")

    case make_request(url) do
      {:ok, %{"items" => items}} when is_list(items) ->
        items
        |> Enum.map(&parse_google_books_search_item(&1, excluded_isbns, excluded_descriptors))
        |> Enum.reject(&is_nil/1)
        |> pick_best_candidate(:google_books, signals)

      {:error, reason} ->
        Stacks.CircuitBreakers.melt(@google_books_fuse)
        {:error, reason}

      _ ->
        {:error, :not_found}
    end
  end

  defp parse_google_books_search_item(item, excluded_isbns, excluded_descriptors) do
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

      metadata = %{
        title: info["title"],
        subtitle: info["subtitle"],
        author: authors,
        description: info["description"],
        cover_image_url: get_in(info, ["imageLinks", "thumbnail"]),
        publisher: info["publisher"],
        publication_year: parse_year(info["publishedDate"]),
        page_count: info["pageCount"],
        subjects: info["categories"] || [],
        google_books_id: item["id"],
        source: :google_books
      }

      apply_ol_exclusion(:google_books, isbn, metadata, excluded_isbns, excluded_descriptors)
    else
      nil
    end
  end

  defp apply_ol_exclusion(source, isbn, metadata, excluded_isbns, excluded_descriptors) do
    has_exclusions? = excluded_isbns != [] or excluded_descriptors != []

    cond do
      excluded_isbn?(isbn, excluded_isbns) ->
        if has_exclusions?, do: log_resolver_skip(source, isbn, metadata, :excluded_isbn)
        nil

      excluded_descriptor?(metadata, excluded_descriptors) ->
        if has_exclusions?, do: log_resolver_skip(source, isbn, metadata, :excluded_descriptor)
        nil

      true ->
        if has_exclusions?, do: log_resolver_accept(source, isbn, metadata)
        {:ok, isbn, metadata}
    end
  end

  defp log_resolver_skip(source, isbn, metadata, reason) do
    Logger.info(
      "ISBNResolver.#{source}: skip isbn=#{isbn} title=#{inspect(metadata.title)} author=#{inspect(metadata.author)} reason=#{reason}"
    )
  end

  defp log_resolver_accept(source, isbn, metadata) do
    Logger.info(
      "ISBNResolver.#{source}: ACCEPT isbn=#{isbn} title=#{inspect(metadata.title)} author=#{inspect(metadata.author)}"
    )
  end

  defp pick_best_candidate(candidates, source, signals) do
    pairs = Enum.map(candidates, fn {:ok, isbn, meta} -> {isbn, meta} end)

    case CandidateScorer.pick_best(pairs, signals) do
      :empty ->
        {:error, :not_found}

      {:ok, {_score, isbn, meta} = best, runner_up} ->
        if length(pairs) > 1, do: log_scored_decision(source, length(pairs), best, runner_up)
        {:ok, isbn, meta}

      {:floored, best, runner_up} ->
        if length(pairs) > 1, do: log_scored_decision(source, length(pairs), best, runner_up)
        log_floored_decision(source, length(pairs), best)
        {:error, :not_found}
    end
  end

  defp log_floored_decision(source, count, {score, isbn, meta}) do
    Logger.info(
      "ISBNResolver.#{source}: floored best of #{count} candidate(s); best=#{isbn} " <>
        "title=#{inspect(meta.title)} score=#{Float.round(score, 2)} < " <>
        "floor=#{CandidateScorer.default_floor()}, no author corroboration — treating as no match"
    )
  end

  defp log_scored_decision(source, count, {best_score, best_isbn, best_meta}, runner_up) do
    runner_up_str =
      case runner_up do
        {score, isbn, meta} ->
          " runner_up=#{isbn} title=#{inspect(meta.title)} score=#{Float.round(score, 2)}"

        nil ->
          ""
      end

    Logger.info(
      "ISBNResolver.#{source}: scored #{count} candidates; best=#{best_isbn} " <>
        "title=#{inspect(best_meta.title)} score=#{Float.round(best_score, 2)};#{runner_up_str}"
    )
  end

  @doc """
  ISBN-13s of the other editions of an Open Library **work**.

  A work is the abstract book; an edition is a particular printing with its own ISBN.
  Shops stock whichever edition they stock, so knowing a work's editions is what lets a
  price lookup find the copy a reader can actually buy — Exclusive Books carries six
  ISBNs of *The Name of the Rose*, two of them Spanish.

  Lives here rather than in a worker so it reuses this module's Open Library fuse and
  its injectable HTTP client. A new module making its own request would be a second
  egress to the same upstream with its own failure behaviour — the mistake that left
  `DiscoverBookstoreEventsJob` bypassing robots.txt for months.

  Returns ISBN-13s only, deduplicated, capped at `#{@max_editions_per_work}`. ISBN-10s
  are deliberately dropped: the ISBN hard gate is expressed in 13s, and returning a
  mixture would push the normalising decision onto every caller.

  `{:error, :circuit_open}` when the Open Library fuse is blown, so a caller can tell
  "no editions" from "could not ask".
  """
  @spec editions_for_work(String.t()) :: {:ok, [String.t()]} | {:error, error_reason()}
  def editions_for_work(work_id) when is_binary(work_id) and work_id != "" do
    case :fuse.ask(@open_library_fuse, :sync) do
      :ok -> do_editions_request(work_id)
      :blown -> {:error, :circuit_open}
    end
  end

  def editions_for_work(_work_id), do: {:error, :not_found}

  defp do_editions_request(work_id) do
    url = "#{@open_library_works_url}/#{work_id}/editions.json?limit=#{@max_editions_per_work}"

    case make_request(url) do
      {:ok, body} ->
        {:ok, parse_edition_isbns(body)}

      {:error, reason} ->
        Stacks.CircuitBreakers.melt(@open_library_fuse)
        {:error, reason}
    end
  end

  defp parse_edition_isbns(%{"entries" => entries}) when is_list(entries) do
    entries
    |> Enum.flat_map(fn
      entry when is_map(entry) -> entry |> Map.get("isbn_13") |> list_or_empty()
      _ -> []
    end)
    |> Enum.map(&String.replace(&1, ~r/[^0-9Xx]/, ""))
    |> Enum.filter(&(String.length(&1) == 13))
    |> Enum.uniq()
    |> Enum.take(@max_editions_per_work)
  end

  defp parse_edition_isbns(_), do: []

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
    case Map.get(data, "ISBN:#{isbn}") do
      nil -> {:error, :not_found}
      book_data -> {:ok, build_open_library_metadata(book_data)}
    end
  end

  defp parse_open_library(_, _), do: {:error, :not_found}

  defp build_open_library_metadata(book_data) do
    ol_key = book_data["key"]

    %{
      title: book_data["title"],
      author: ol_authors(book_data),
      description: ol_description(book_data),
      cover_image_url: get_in(book_data, ["cover", "large"]),
      publisher: ol_publisher(book_data),
      publication_year: parse_year(book_data["publish_date"]),
      page_count: book_data["number_of_pages"],
      subjects: extract_subjects(book_data["subjects"]),
      open_library_id: ol_key,
      open_library_work_id: ol_work_id(book_data, ol_key),
      source: :open_library
    }
  end

  defp ol_authors(book_data) do
    book_data
    |> Map.get("authors")
    |> list_or_empty()
    |> Enum.map_join(", ", &(&1["name"] || ""))
  end

  defp ol_publisher(book_data) do
    book_data
    |> Map.get("publishers")
    |> list_or_empty()
    |> List.first()
    |> then(&if(is_map(&1), do: &1["name"], else: &1))
  end

  defp ol_description(book_data) do
    case list_or_empty(Map.get(book_data, "excerpts")) do
      [%{"text" => text} | _] -> text
      _ -> nil
    end
  end

  defp ol_work_id(book_data, ol_key) do
    work_key =
      book_data
      |> Map.get("works")
      |> list_or_empty()
      |> List.first()
      |> then(fn
        %{"key" => k} -> k
        _ -> nil
      end)

    derive_work_id(work_key, ol_key)
  end

  defp derive_work_id(work_key, _ol_key) when is_binary(work_key),
    do: work_key |> String.split("/") |> List.last()

  defp derive_work_id(_work_key, ol_key) when is_binary(ol_key) do
    if String.contains?(ol_key, "/works/"),
      do: ol_key |> String.split("/") |> List.last(),
      else: nil
  end

  defp derive_work_id(_work_key, _ol_key), do: nil

  defp list_or_empty(value) when is_list(value), do: value
  defp list_or_empty(_), do: []

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
