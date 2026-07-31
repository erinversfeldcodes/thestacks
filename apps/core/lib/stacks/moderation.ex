defmodule Stacks.Moderation do
  @moduledoc """
  Moderation pipeline for uploaded book images.

  Runs a 3-step pipeline:
  1. is_book? — vision model checks if image contains a book
  2. extract_all — vision model extracts all books from the image
  3. store — resolves ISBNs/metadata and stores each book as `public`.
     Age-gating is NOT decided here. A book becomes age-gated only when a
     person marks it "adults only" (`Stacks.Books.set_visibility_tier/3`) or
     the platform owner moderates it — never from automated classification.

  Sidecar API contract:
  - POST /classify  → %{"classification" => "CLASSIFICATION_RESULT_BOOK"|"CLASSIFICATION_RESULT_NOT_BOOK"|"CLASSIFICATION_RESULT_AMBIGUOUS", "confidence" => float, "model_used" => str}
  - POST /extract   → %{"books" => [%{"title" => str|nil, "author" => str|nil, "potential_isbns" => [str], "raw_text" => str|nil, "confidence" => float}], "model_used" => str}

  The pipeline accepts either `image_b64` (base64-encoded) or `image_url`
  (presigned URL) in the context map. The `image_url` path is preferred for
  new uploads stored in object storage; `image_b64` is retained for backwards
  compatibility with in-flight jobs.
  """

  require Logger

  alias Stacks.AI.Client, as: AIClient
  alias Stacks.AI.VisionError
  alias Stacks.Books
  alias Stacks.Books.ISBNResolver
  alias Stacks.Workers.EnrichBookJob

  @typedoc """
  Closed set of reasons the pipeline fails, following the convention
  `Stacks.Books.ISBNResolver.error_reason/0` documents: the underlying client's
  closed set, extended with the two determinations this layer makes itself.

  `:not_a_book` and `:isbn_not_found` are conclusions about the image, so the
  worker cancels on them. Everything else is a `Stacks.AI.VisionError.t/0` and
  carries its own determination.

  Adding a reason here means deciding, in `Stacks.Workers.IdentifyBookJob`,
  whether it is a determination or a fault: `classify_failure/1` routes it, and
  `rejection_token/1` names what the reader is told. Neither guesses — a reason
  outside `Stacks.AI.VisionError.t/0` is retried and reported as
  `processing_failed`, which is the safe answer, not a silent one.
  """
  @type failure_reason :: Stacks.AI.VisionError.t() | :not_a_book | :isbn_not_found

  @typedoc """
  Pipeline result. The success shape carries both the resolved books and any
  candidates that failed to resolve so observability events can be emitted
  per-failure rather than silently dropped. `rejected` is a list of
  `{isbn_or_title, reason}` tuples (the first element is the candidate's
  potential ISBN if available, otherwise its title).
  """
  @type pipeline_result ::
          {:ok, %{resolved: [Stacks.Books.Book.t()], rejected: [{String.t(), atom()}]}}
          | {:error, failure_reason()}

  @doc """
  Runs the full moderation pipeline for an uploaded image.

  Expects `context` to include one of:
  - `image_url` — presigned URL to the image in object storage (preferred)
  - `image_b64` — base64-encoded image bytes (legacy/backwards compat)

  Plus `user_id`, `image_id` for logging/context.

  Returns `{:ok, %{resolved: [Book.t()], rejected: [{candidate_id, reason}]}}`
  on success (at least one book identified). The `rejected` list surfaces
  candidates that failed to resolve in a multi-book image — callers should
  emit observability events per entry. Returns `{:error, reason}` if no
  candidates resolved or the image is not a book.
  """
  @spec run_pipeline(map()) :: pipeline_result()
  def run_pipeline(%{image_url: image_url} = context) do
    analyze(build_payload(%{image_url: image_url}, context), context)
  end

  def run_pipeline(%{image_b64: image_b64} = context) do
    analyze(build_payload(%{image: image_b64}, context), context)
  end

  # Threads the rejection-retry exclusion list through to the vision
  # sidecar so the model can be steered away from previously-rejected
  # books. The list is empty for first-attempt jobs; the proto field's
  # default-empty contract means the payload is wire-compatible either
  # way. Missing or non-list values fall through to no exclusions.
  defp build_payload(base, context) do
    case Map.get(context, :excluded_books) do
      list when is_list(list) and list != [] -> Map.put(base, :excluded_books, list)
      _ -> base
    end
  end

  # Single-request classify + extract via the vision service's /analyze
  # endpoint. Replaces the earlier two-call pattern (is_book then
  # extract_isbn — either sequential or a parallel fan-out that wasted
  # a Modal call on non-books). One HTTP round-trip, one Modal container
  # invocation. The service short-circuits internally when classification
  # is not BOOK, returning an empty books list without running the
  # expensive extract step.
  defp analyze(payload, context) do
    case AIClient.call_vision("analyze", payload) do
      {:ok, %{"classification" => "CLASSIFICATION_RESULT_BOOK", "books" => []}} ->
        emit_classification(:book)
        {:error, :isbn_not_found}

      {:ok, %{"classification" => "CLASSIFICATION_RESULT_BOOK", "books" => books} = resp}
      when is_list(books) ->
        emit_classification(:book)
        Logger.info("Moderation: /analyze returned #{length(books)} candidate(s)")
        # Propagate `model_used` so downstream can tell barcode-sourced
        # (local_ocr) ISBNs apart from VLM-extracted ones. The fast-path
        # metadata skip is only safe when the source is local_ocr — the
        # VLM can produce strings that happen to pass the ISBN-13 check
        # digit but aren't real books, so we don't trust it unilaterally.
        context_with_source =
          Map.put(context, :vision_model_used, Map.get(resp, "model_used"))

        resolve_and_store_all(books, context_with_source)

      {:ok, %{"classification" => classification}} ->
        emit_classification(classification_outcome(classification))
        {:error, :not_a_book}

      {:error, reason} ->
        {:error, reason}

      # A 200 whose body carries no `classification` is a contract violation by
      # the sidecar, not a determination about the image — a response that
      # cannot say what it concluded is not evidence that nothing went wrong.
      # Reported as a fault so it stays retryable and shows up as one, rather
      # than falling through as a bare `{:ok, %{}}` the worker's `case` cannot
      # match. That fall-through was real: it raised CaseClauseError, was
      # rescued into `{:error, %CaseClauseError{}}`, retried to exhaustion, and
      # left the image row `pending` for ever.
      {:ok, other} ->
        Logger.error(
          "Moderation: /analyze returned an unrecognised response shape " <>
            "(keys: #{inspect(other |> Map.keys() |> Enum.sort())})"
        )

        {:error, VisionError.from_transport(:unrecognised_response)}
    end
  end

  # Step-1 classification funnel counter. `outcome` is a whitelisted atom
  # (:book / :not_a_book / :ambiguous / :unknown) — NEVER an ISBN, title,
  # or other user input (GDPR: telemetry is a warehouse-adjacent sink).
  defp emit_classification(outcome) do
    :telemetry.execute([:stacks, :moderation, :classification], %{count: 1}, %{outcome: outcome})
  end

  defp classification_outcome("CLASSIFICATION_RESULT_BOOK"), do: :book
  defp classification_outcome("CLASSIFICATION_RESULT_NOT_BOOK"), do: :not_a_book
  defp classification_outcome("CLASSIFICATION_RESULT_AMBIGUOUS"), do: :ambiguous
  defp classification_outcome(_), do: :unknown

  # Expands compound candidates where the vision model joined multiple book titles
  # with " OR " (e.g. "Things I Don't Want to Know OR The Cost of Living").
  # Each part becomes its own candidate with the same author/raw_text.
  defp expand_compound_candidates(candidates) do
    Enum.flat_map(candidates, fn candidate ->
      title = candidate["title"] || ""

      case String.split(title, ~r/\s+OR\s+/, parts: 2) do
        [part1, part2] ->
          # Compound-expansion frequency counter: one event per split, with
          # the number of parts as a measurement. No title/PII in metadata.
          :telemetry.execute(
            [:stacks, :moderation, :compound_expansion],
            %{count: 1, parts: 2},
            %{}
          )

          [
            Map.put(candidate, "title", String.trim(part1)),
            Map.put(candidate, "title", String.trim(part2))
          ]

        _ ->
          [candidate]
      end
    end)
  end

  # For each candidate, resolve to an ISBN (direct or via title search) and
  # create/find the book. Returns
  # `{:ok, %{resolved: [books], rejected: [{candidate_id, reason}]}}`.
  # `candidate_id` is the candidate's potential ISBN if present, otherwise
  # its title. Fails only if NONE of the candidates resolve.
  #
  # Candidates are resolved concurrently via `Task.async_stream`. Each
  # candidate triggers an Open Library (sometimes Google Books) HTTP
  # lookup plus DB work; sequential processing of 2+ candidates easily
  # adds 0.5–1.5s to the overall pipeline. With concurrency, total wait
  # is bounded by the slowest candidate rather than their sum. Failures
  # in one candidate don't affect the others — they surface in the
  # `rejected` list so the caller can emit per-candidate
  # `image.rejected` events for observability.
  defp resolve_and_store_all(candidates, context) do
    Stacks.Telemetry.phase(
      :isbn_resolution,
      %{upload_id: Map.get(context, :image_id), candidate_count: length(candidates)},
      fn -> do_resolve_and_store_all(candidates, context) end
    )
  end

  defp do_resolve_and_store_all(candidates, context) do
    excluded_isbns = Map.get(context, :excluded_isbns, [])

    expanded =
      candidates
      |> expand_compound_candidates()
      |> drop_excluded_isbn_candidates(excluded_isbns)

    concurrency = max(length(expanded), 1)

    outcomes =
      expanded
      |> Enum.with_index(1)
      |> Task.async_stream(
        fn {candidate, idx} -> resolve_and_store(candidate, idx, context) end,
        # Bounded by the vision client's own per-call ceiling, read from it
        # rather than restated: a genuinely slow candidate should not be killed
        # before the call it is waiting on has itself given up.
        timeout: AIClient.receive_timeout_ms(),
        max_concurrency: concurrency,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, outcome} ->
          outcome

        {:exit, reason} ->
          Logger.warning("Moderation: candidate task exited: #{inspect(reason)}")
          {:rejected, "unknown", :task_exit}
      end)

    Enum.each(outcomes, &emit_resolution_outcome/1)

    resolved = for {:resolved, book} <- outcomes, do: book
    rejected = for {:rejected, candidate_id, reason} <- outcomes, do: {candidate_id, reason}

    case resolved do
      [] -> {:error, :isbn_not_found}
      _ -> {:ok, %{resolved: resolved, rejected: rejected}}
    end
  end

  # Step-2 ISBN-resolution funnel counter, one per candidate. `outcome` is a
  # whitelisted atom: :resolved for a resolved book, or the (bounded)
  # rejection reason (:isbn_not_found / :low_confidence / :invalid_book /
  # :store_failed / :task_exit), coerced to :other for anything unexpected.
  # No ISBN/title/PII ever reaches metadata.
  @resolution_reasons [:isbn_not_found, :low_confidence, :invalid_book, :store_failed, :task_exit]

  defp emit_resolution_outcome({:resolved, _book}), do: emit_resolution(:resolved)

  defp emit_resolution_outcome({:rejected, _candidate_id, reason}),
    do: emit_resolution(whitelist_resolution_reason(reason))

  defp emit_resolution(outcome) do
    :telemetry.execute([:stacks, :moderation, :isbn_resolution], %{count: 1}, %{outcome: outcome})
  end

  defp whitelist_resolution_reason(reason) when reason in @resolution_reasons, do: reason
  defp whitelist_resolution_reason(_), do: :other

  # Rejection-retry: a candidate whose direct ISBN matches a previously
  # rejected book is dropped before any DB/HTTP work. Without this, the
  # VLM could return the exact ISBN of a book the user already said "no"
  # to (e.g. a screenshot whose barcode the model misread on round 1
  # then read the same way on round 2) and we'd resolve it again. The
  # comparison is hyphen/space- AND ISBN-10/13-form-insensitive (both
  # sides canonicalised via `Books.canonical_isbn13/1`) — see
  # `Stacks.Books.ISBNResolver` `excluded_isbn?/2` for the same match.
  #
  # Candidates without a `potential_isbns` field (or with an empty list)
  # fall through to the title-search path where exclusions are applied
  # at the resolver layer.
  defp drop_excluded_isbn_candidates(candidates, []), do: candidates

  defp drop_excluded_isbn_candidates(candidates, excluded_isbns) do
    Enum.reject(candidates, fn candidate ->
      case Map.get(candidate, "potential_isbns") do
        [isbn | _] when is_binary(isbn) -> excluded_isbn?(isbn, excluded_isbns)
        _ -> false
      end
    end)
  end

  defp excluded_isbn?(isbn, excluded_isbns) do
    normalised = normalise_isbn(isbn)
    normalised != "" and Enum.any?(excluded_isbns, &(normalise_isbn(&1) == normalised))
  end

  # Canonical ISBN-13 on both sides: a VLM candidate carrying the
  # ISBN-10 form of a rejected book's ISBN-13 must still be dropped.
  defp normalise_isbn(value) when is_binary(value), do: Books.canonical_isbn13(value)

  defp normalise_isbn(_), do: ""

  defp resolve_and_store(candidate, idx, context) do
    case check_confidence(candidate, idx) do
      :ok -> do_resolve_and_store(candidate, idx, context)
      {:skip, reason} -> {:rejected, candidate_identifier(candidate), reason}
    end
  end

  defp do_resolve_and_store(candidate, idx, context) do
    case resolve_candidate(candidate, idx, context) do
      {:ok, isbn, metadata} ->
        case store_book(isbn, metadata, context) do
          {:ok, book} ->
            {:resolved, book}

          {:error, reason} ->
            Logger.warning(
              "Moderation: candidate #{idx} ISBN #{isbn} failed to store: #{inspect(reason)}"
            )

            {:rejected, isbn, store_failure_reason(reason)}
        end

      {:error, reason} ->
        Logger.warning("Moderation: candidate #{idx} failed to resolve: #{inspect(reason)}")
        {:rejected, candidate_identifier(candidate), reason}
    end
  end

  # Confidence gate (Issue #167): the vision model returns a per-candidate
  # `confidence` score (0.0–1.0). Candidates below the configured threshold
  # are skipped here, before any external (Open Library / Google Books) or
  # internal (EnrichBookJob enqueue) work is done — low-confidence guesses
  # otherwise inflate API traffic and burn the worker's retry budget on
  # candidates the model itself flagged as weak.
  #
  # Candidates with NO `confidence` field (or `nil`) are treated as
  # historical (pre-prompt-v2 vision payloads): process normally rather
  # than fail-closed, so old in-flight jobs don't regress.
  defp check_confidence(candidate, idx) do
    case candidate_confidence(candidate) do
      nil ->
        :ok

      confidence when is_number(confidence) ->
        threshold = enrichment_confidence_threshold()

        if confidence < threshold do
          isbn = candidate_isbn(candidate)

          :telemetry.execute(
            [:stacks, :enrichment, :candidate, :skipped],
            %{count: 1, confidence: confidence},
            %{isbn: isbn, reason: :low_confidence, threshold: threshold}
          )

          Logger.info(
            "Moderation: candidate #{idx} skipped — confidence #{confidence} below threshold #{threshold}"
          )

          {:skip, :low_confidence}
        else
          :ok
        end
    end
  end

  defp candidate_confidence(%{"confidence" => confidence}), do: confidence
  defp candidate_confidence(_), do: nil

  defp candidate_isbn(%{"potential_isbns" => [isbn | _]})
       when is_binary(isbn) and isbn != "",
       do: isbn

  defp candidate_isbn(_), do: nil

  defp enrichment_confidence_threshold do
    Application.get_env(:core, :enrichment_confidence_threshold, 0.5)
  end

  # Best-effort identifier for the rejected list payload. Prefer the candidate's
  # potential ISBN; fall back to its title; finally fall back to a sentinel
  # so consumers always see a non-empty string.
  defp candidate_identifier(%{"potential_isbns" => [isbn | _]})
       when is_binary(isbn) and isbn != "",
       do: isbn

  defp candidate_identifier(%{"title" => title}) when is_binary(title) and title != "", do: title
  defp candidate_identifier(_), do: "unknown"

  defp store_failure_reason(%Ecto.Changeset{}), do: :invalid_book
  defp store_failure_reason(reason) when is_atom(reason), do: reason
  defp store_failure_reason(_), do: :store_failed

  defp resolve_candidate(%{"potential_isbns" => [isbn | _]} = _candidate, idx, _context)
       when is_binary(isbn) and isbn != "" do
    Logger.info("Moderation: candidate #{idx} has direct ISBN #{isbn}")
    {:ok, isbn, nil}
  end

  defp resolve_candidate(candidate, idx, context) do
    title = normalise_nullish_text(candidate["title"])
    author = normalise_author(candidate["author"])
    raw_text = normalise_nullish_text(candidate["raw_text"])
    excluded_isbns = Map.get(context, :excluded_isbns, [])
    excluded_descriptors = Map.get(context, :excluded_books, [])

    Logger.info(
      "Moderation: candidate #{idx} has no ISBN, searching (title=#{inspect(title)}, author=#{inspect(author)}, raw_text=#{inspect(raw_text)})"
    )

    case title_fallback(title, author, raw_text, excluded_isbns, excluded_descriptors) do
      {:ok, isbn, metadata} -> {:ok, isbn, metadata}
      error -> error
    end
  end

  # The VLM sometimes emits a placeholder STRING instead of omitting a
  # field: `author: "null"` was observed in production, which went out
  # as a literal `inauthor:null` Google Books query term and was treated
  # as a real author name by candidate scoring. Normalise null-ish
  # author strings to nil at the single point where VLM candidates are
  # read (`resolve_candidate/3`) — `ISBNResolver.search_by_title/4`
  # already drops author params for nil, and `CandidateScorer`'s author
  # component treats a missing author as no-evidence-no-penalty.
  @nullish_author_values ["null", "none", "n/a", "unknown", ""]

  defp normalise_author(value) when is_binary(value) do
    if String.downcase(String.trim(value)) in @nullish_author_values, do: nil, else: value
  end

  defp normalise_author(_), do: nil

  # Title and raw_text get the conservative rule: only the literal
  # "null" placeholder is dropped. A real book could be titled
  # "Unknown" or "None", but no book is titled exactly "null".
  defp normalise_nullish_text(value) when is_binary(value) do
    if String.downcase(String.trim(value)) == "null", do: nil, else: value
  end

  defp normalise_nullish_text(_), do: nil

  defp title_fallback(nil, _author, _raw_text, _excluded_isbns, _excluded_descriptors),
    do: {:error, :isbn_not_found}

  defp title_fallback("", _author, _raw_text, _excluded_isbns, _excluded_descriptors),
    do: {:error, :isbn_not_found}

  defp title_fallback(title, author, raw_text, excluded_isbns, excluded_descriptors) do
    case ISBNResolver.search_by_title(title, author, raw_text,
           excluded_isbns: excluded_isbns,
           excluded_book_descriptors: excluded_descriptors
         ) do
      {:ok, isbn, metadata} ->
        Logger.info("Moderation: title search found ISBN #{isbn} for '#{title}'")
        {:ok, isbn, metadata}

      {:error, :not_found} ->
        Logger.warning("Moderation: title search found no results for '#{title}'")
        {:error, :isbn_not_found}
    end
  end

  defp store_book(isbn, prefetched_metadata, context) do
    Stacks.Telemetry.phase(
      :persistence,
      %{upload_id: Map.get(context, :image_id), isbn: isbn},
      fn ->
        {metadata, used_fast_path} = resolve_metadata(isbn, prefetched_metadata, context)
        attrs = build_book_attrs(isbn, metadata, used_fast_path, context)

        case Books.find_existing(isbn) do
          nil -> Books.create(attrs)
          existing -> {:ok, existing}
        end
      end
    )
  end

  # `used_fast_path` tracks whether the synchronous OL/GB lookup was
  # skipped because the ISBN checksum was valid. Without this flag we
  # can't distinguish two `metadata == %{}` cases that must be handled
  # differently:
  #   * fast path fired → use placeholder title, enqueue enrichment
  #   * sync lookup returned :not_found → leave title nil so the
  #     changeset validation rejects the row (VLM-hallucinated ISBNs
  #     that are neither checksum-valid nor in OL/GB shouldn't pollute
  #     the books table)
  defp resolve_metadata(_isbn, prefetched_metadata, _context)
       when not is_nil(prefetched_metadata) do
    {prefetched_metadata, false}
  end

  defp resolve_metadata(isbn, _prefetched_metadata, context) do
    if fast_path?(isbn, context) do
      enqueue_metadata_enrichment(isbn)
      {%{}, true}
    else
      case Books.resolve_isbn(isbn) do
        {:ok, data} -> {data, false}
        _ -> {%{}, false}
      end
    end
  end

  # Fast path: a checksum-valid ISBN that came from local OCR (barcode
  # decode) is trustworthy — zbar rejects invalid EAN-13 before we ever
  # see it, so the string in hand is a real ISBN. Skip the synchronous
  # OL/GB round-trip (~400ms+) on the upload hot path and let
  # `EnrichBookJob` fill in title/author/cover asynchronously.
  #
  # Intentionally NOT applied to VLM-extracted ISBNs: the model can read
  # garbled text and produce a 13-digit string that passes the check
  # digit (~10% of random 13-digit strings) but isn't a real book. Only
  # `model_used == "local_ocr"` gives us scanner-level confidence.
  defp fast_path?(isbn, context) do
    context[:vision_model_used] == "local_ocr" and Books.valid_isbn_checksum?(isbn)
  end

  # Books enter the system `public` by default (the schema default on
  # `op.books.visibility_tier`). We deliberately do NOT set a
  # `"visibility_tier"` key here: the automatic subject→BISAC age-gate
  # classifier was removed — a book becomes age-gated only when a PERSON
  # marks it (see `Stacks.Books.set_visibility_tier/3`), never because
  # code guessed from metadata. `bisac_codes` carries only real codes the
  # resolver supplied; it is no longer derived from a fake genre map.
  defp build_book_attrs(isbn, metadata, used_fast_path, context) do
    base_attrs = %{
      "isbn" => isbn,
      "title" => derive_title(isbn, metadata, used_fast_path),
      # ISBN provenance (#335 D1). The fast path deliberately skipped the
      # OL/GB round-trip, so nothing external has confirmed this ISBN — say
      # so on the row rather than leaving it to be inferred from the
      # `"ISBN <isbn>"` placeholder title, which `EnrichBookJob` overwrites
      # the moment enrichment succeeds. Otherwise the identifiers the
      # resolver returned name the source (Books.verification_source_from/1).
      #
      # The fast-path branch is written out even though `resolve_metadata/3`
      # currently returns `%{}` alongside `used_fast_path == true`, which the
      # derivation would map to the same answer. That coincidence is not the
      # reason: `used_fast_path` means "we deliberately skipped the external
      # lookup", and if the fast path ever carries partial metadata, deriving
      # from it would silently claim a verification that never happened.
      "verification_source" =>
        if(used_fast_path,
          do: "barcode_unverified",
          else: Books.verification_source_from(metadata)
        ),
      "subjects" => metadata[:subjects] || [],
      "bisac_codes" => metadata[:bisac_codes] || [],
      "description" => metadata[:description],
      "cover_image_url" => metadata[:cover_image_url],
      "publisher" => metadata[:publisher],
      "publication_year" => metadata[:publication_year],
      "page_count" => metadata[:page_count],
      "author" => metadata[:author]
    }

    Map.merge(base_attrs, context[:book_attrs] || %{})
  end

  defp derive_title(isbn, metadata, used_fast_path) do
    cond do
      metadata[:title] -> metadata[:title]
      used_fast_path -> "ISBN #{isbn}"
      true -> nil
    end
  end

  defp enqueue_metadata_enrichment(isbn) do
    case %{"isbn" => isbn}
         |> EnrichBookJob.new()
         |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Moderation: failed to enqueue EnrichBookMetadataJob for #{isbn}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "Moderation: EnrichBookMetadataJob enqueue raised for #{isbn}: #{inspect(exception)}"
      )

      :ok
  end
end
