defmodule Stacks.Books.ISBNResolver do
  @moduledoc """
  Resolves ISBNs to book metadata by querying Open Library (primary)
  and Google Books (fallback). Uses Finch for HTTP and Fuse circuit breakers
  for resilience.
  """

  require Logger

  alias Stacks.Books.CandidateScorer
  alias Stacks.Books.HttpClientBehaviour
  alias Stacks.Books.ISBNResolverCache
  alias Stacks.Books.TitleSearchCache

  @typedoc """
  Closed set of error reasons returned by `resolve/1`. Extends the
  underlying `HttpClientBehaviour.error_reason()` with two resolver-level
  reasons: `:not_found` (no upstream returned a match) and
  `:circuit_open` (the relevant Fuse breaker is blown). Adding a new
  reason here requires adding a matching clause in
  `Stacks.Workers.EnrichBookJob.outcome_tag/1` — dialyzer enforces the
  exhaustiveness end-to-end.
  """
  @type error_reason ::
          HttpClientBehaviour.error_reason()
          | :not_found
          | :circuit_open

  @open_library_url "https://openlibrary.org/api/books"
  @open_library_search_url "https://openlibrary.org/search.json"
  @google_books_url "https://www.googleapis.com/books/v1/volumes"

  # Hard deadline for the parallel OL + GB race. Each individual upstream
  # has its own HTTP client timeout, but this cap protects the upload job
  # from a truly stuck external service.
  #
  # Bumped 5_000 → 8_000 after the Google Books API quota was exhausted
  # in the chore/enable-pipelines preview (`quota_limit_value: "0"`):
  # with GB returning a fast 429, the race effectively became a solo OL
  # call, and OL p95 has crept above 5s during peak periods. Hitting the
  # 5s race deadline on a healthy OL call was forcing `EnrichBookJob` to
  # retry against the (now cache-safe) transient-error path. 8s keeps
  # the upload hot path well under the 30s Finch timeout while removing
  # most of the transient race-timeout false negatives.
  @race_timeout_ms 8_000

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
          {:ok, String.t(), map()} | {:error, :not_found}
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
        # Bypass the cache: a memoised entry was computed without the
        # exclusion list and would happily return the very ISBN/book we
        # were asked to skip. Don't write the result back either — the
        # next first-attempt caller (no exclusions) would inherit a
        # result that's already been narrowed.
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

    # The ORIGINAL extracted signals, threaded down to candidate scoring.
    # Scoring must see the full VLM title/author/raw_text — NOT the
    # broadened query variant that produced the HTTP request — or the
    # disambiguating tokens (e.g. subtitle keywords absorbed into the
    # VLM title) are lost by the time we rank upstream docs.
    signals = %{title: title, author: author, raw_text: raw_text}

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

    Enum.find_value(candidates, {:error, :not_found}, fn candidate ->
      try_candidate(candidate, signals, excluded_isbns, excluded_descriptors)
    end)
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
  #
  # When `excluded_isbns` or `excluded_descriptors` is non-empty, an
  # OL/GB hit whose ISBN matches an entry, OR whose (title, author)
  # pair matches a "Title by Author" descriptor, is mapped to `nil` so
  # `Enum.find_value/3` skips to the next candidate query variant.
  # The function already tries progressively broader queries, so this
  # naturally falls through to the next non-excluded match without
  # changing the candidate list.
  #
  # Descriptor matching is the load-bearing case when the user rejects
  # a book that has multiple editions in OL/GB (e.g. two Tor editions
  # of the same Orson Scott Card title): ISBN exclusion alone walks
  # from one edition to the next; (title, author) exclusion treats all
  # editions as the same book and skips past them.
  #
  # Known trade-off: the OL-vs-GB race keeps first-upstream-wins
  # semantics BETWEEN the two providers; candidate scoring (see
  # `pick_best_candidate/3`) applies WITHIN each provider's result list.
  # A better-scoring doc in the slower provider's response can lose to
  # the faster provider's best doc.
  defp try_candidate({t, a}, signals, excluded_isbns, excluded_descriptors) do
    ol =
      Task.async(fn ->
        wrap_3tuple(
          open_library_title_search(t, a, signals, excluded_isbns, excluded_descriptors)
        )
      end)

    gb =
      Task.async(fn ->
        wrap_3tuple(google_books_search(t, a, signals, excluded_isbns, excluded_descriptors))
      end)

    case await_first_success([ol, gb], {:error, :not_found}) do
      {:ok, {isbn, metadata}} ->
        cond do
          excluded_isbn?(isbn, excluded_isbns) -> nil
          excluded_descriptor?(metadata, excluded_descriptors) -> nil
          true -> {:ok, isbn, metadata}
        end

      _ ->
        nil
    end
  end

  defp wrap_3tuple({:ok, isbn, metadata}), do: {:ok, {isbn, metadata}}
  defp wrap_3tuple(other), do: other

  # Hyphen/space-insensitive ISBN membership check. The upstream stores
  # rejected ISBNs as `book.primary_edition.isbn` (usually a clean
  # 13-digit string), but the OL/GB search-result ISBNs sometimes
  # arrive with formatting hyphens. Normalise both sides before compare.
  defp excluded_isbn?(_isbn, []), do: false

  defp excluded_isbn?(isbn, excluded_isbns) do
    normalised = normalise_isbn_for_compare(isbn)

    normalised != "" and
      Enum.any?(excluded_isbns, &(normalise_isbn_for_compare(&1) == normalised))
  end

  defp normalise_isbn_for_compare(value) when is_binary(value),
    do: value |> String.replace(~r/[\s\-]/, "") |> String.upcase()

  defp normalise_isbn_for_compare(_), do: ""

  # (title, author) pair membership check. Upstream rejected books arrive
  # as "Title by Author" strings (see `UploadController.describe_book/1`).
  # OL/GB metadata gives us discrete title + author fields; rebuild the
  # same "Title by Author" form and compare normalised (lowercase, strip
  # punctuation, collapse whitespace) on both sides. This catches the
  # "two editions of the same book under different ISBNs" case where
  # ISBN-only exclusion would walk from one edition to the next forever.
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
    # Strip apostrophes FIRST (both ASCII and typographic) so possessives
    # collapse into a single token: "TRAMP'S" → "TRAMPS". Without this,
    # the apostrophe creates a word boundary and the acronym join below
    # sees an orphan single letter next to the FOLLOWING word —
    # "TRAMP'S CRYSTAL" → "S C" glued → "SCRYSTAL" — poisoning every
    # enriched query variant (observed in production).
    |> String.replace(~r/['’]/u, "")
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
        # Build candidates for ALL docs, skipping any whose ISBN or
        # (title, author) matches an upstream exclusion (exclusion at
        # the per-doc level is load-bearing: `try_candidate` retries the
        # SAME OL URL across query variants, so excluding only at that
        # level would see the same top doc forever). The surviving
        # candidates are scored against the ORIGINAL VLM signals and the
        # best one wins — taking the first doc instead picks the wrong
        # book when OL's ranking favours an exact-prefix match over the
        # one whose subtitle matches the extracted title.
        docs
        |> Enum.map(&build_ol_metadata(&1, excluded_isbns, excluded_descriptors))
        |> Enum.reject(&is_nil/1)
        |> pick_best_candidate(:open_library, signals)

      {:error, _} ->
        Stacks.CircuitBreakers.melt(@open_library_fuse)
        {:error, :not_found}

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

    # Pull 5 items (was 1) so we can iterate past excluded matches when
    # the user has rejected the top hit. Empty exclusions → same
    # effective behaviour as before; non-empty → walk past the rejected
    # book to the next plausible candidate.
    url = google_books_url("q=#{query}&maxResults=5")

    case make_request(url) do
      {:ok, %{"items" => items}} when is_list(items) ->
        # Same score-everything-pick-best approach as the OL path.
        items
        |> Enum.map(&parse_google_books_search_item(&1, excluded_isbns, excluded_descriptors))
        |> Enum.reject(&is_nil/1)
        |> pick_best_candidate(:google_books, signals)

      {:error, _} ->
        Stacks.CircuitBreakers.melt(@google_books_fuse)
        {:error, :not_found}

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

  # Shared exclusion gate for OL/GB title-search hits. Returns nil when
  # the candidate matches an upstream rejection (ISBN or title+author
  # descriptor), or {:ok, isbn, metadata} otherwise. Diagnostic
  # `Logger.info` only fires when at least one exclusion list is
  # non-empty so first-attempt queries don't log noise.
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

  # Plausibility floor for scored title-search picks. Max-wins alone has
  # no notion of "all the candidates are garbage": a corrupted query can
  # fuzzy-match pure noise (observed in production: VLM title "The
  # Tramp's Crystal City" resolved to "The Crystal Ball a Mystery Story
  # for Girls" at score 1.5) and the resolver would still commit to it.
  #
  # Floor arithmetic: a bare title-token coincidence on a short title
  # scores 3.0–3.5 (the overlap coefficient is generous to short
  # candidate titles — the Crystal City fixtures pin Card/Tarantino/
  # Etchemendy at 3.5), while garbage fuzzy matches land around 1.5.
  # 2.5 splits the two populations. The floor is WAIVED when the
  # candidate has author corroboration (author component scored > 0):
  # a scored author match at any total is strong positive evidence.
  @min_plausible_score 2.5

  # Pick the highest-scoring candidate from one provider's result list.
  #
  # Every candidate — including a lone one — is scored against the
  # original VLM signals by `CandidateScorer.score/2` and checked
  # against the plausibility floor. Single candidates used to skip
  # scoring entirely, but that let a single garbage GB fuzzy-match win
  # unchallenged. `Enum.sort_by/3` is stable, so on a score tie the
  # provider's own ranking decides — exactly the old first-doc-wins
  # behaviour.
  #
  # A below-floor best candidate is treated as no-match ({:error,
  # :not_found} — the same shape as "no docs matched"), so
  # `try_candidate` returns nil and `Enum.find_value` falls through to
  # the next (broader) query variant, ultimately {:error, :not_found}.
  defp pick_best_candidate([], _source, _signals), do: {:error, :not_found}

  defp pick_best_candidate([{:ok, isbn, meta} = only], source, signals) do
    score = CandidateScorer.score(meta, signals)

    if plausible?(score, meta, signals) do
      only
    else
      log_floored_decision(source, 1, {score, isbn, meta})
      {:error, :not_found}
    end
  end

  defp pick_best_candidate(candidates, source, signals) do
    [{best_score, isbn, meta} = best | rest] =
      candidates
      |> Enum.map(fn {:ok, isbn, meta} -> {CandidateScorer.score(meta, signals), isbn, meta} end)
      |> Enum.sort_by(&elem(&1, 0), :desc)

    log_scored_decision(source, length(candidates), best, List.first(rest))

    if plausible?(best_score, meta, signals) do
      {:ok, isbn, meta}
    else
      log_floored_decision(source, length(candidates), best)
      {:error, :not_found}
    end
  end

  defp plausible?(score, meta, signals) do
    score >= @min_plausible_score or CandidateScorer.author_match?(meta, signals)
  end

  defp log_floored_decision(source, count, {score, isbn, meta}) do
    Logger.info(
      "ISBNResolver.#{source}: floored best of #{count} candidate(s); best=#{isbn} " <>
        "title=#{inspect(meta.title)} score=#{Float.round(score, 2)} < " <>
        "floor=#{@min_plausible_score}, no author corroboration — treating as no match"
    )
  end

  # Production debuggability for wrong-book picks: records which
  # candidate won, by how much, and over what runner-up.
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

  # Open Library sparsely populates records — any of `authors`,
  # `publishers`, `works`, `excerpts` may be present with value `nil`.
  # Map.get/3's default only kicks in when the key is MISSING, so we
  # coalesce nil → [] before iterating. Without this, a `"authors": null`
  # payload raises Protocol.UndefinedError out of Enum.map_join, the
  # resolver Task crashes silently, race_resolve falls through to
  # `:not_found`, and the 1h negative cache poisons the ISBN.
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

  # Coalesce nil/non-list values to an empty list. Open Library returns
  # `null` (not the absent key) for several optional fields on sparse
  # records, and Map.get/3's default only fires for absent keys.
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
