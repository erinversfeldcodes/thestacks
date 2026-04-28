defmodule Stacks.Moderation do
  @moduledoc """
  Moderation pipeline for uploaded book images.

  Runs a 4-step pipeline:
  1. is_book? — vision model checks if image contains a book
  2. extract_all — vision model extracts all books from the image
  3. classify_subject — BISAC subject classification from book subjects
  4. store_with_tier — stores books with appropriate visibility_tier

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
  alias Stacks.Books
  alias Stacks.Books.ISBNResolver
  alias Stacks.Workers.EnrichBookJob

  @typedoc """
  Pipeline result. The success shape carries both the resolved books and any
  candidates that failed to resolve so observability events can be emitted
  per-failure rather than silently dropped. `rejected` is a list of
  `{isbn_or_title, reason}` tuples (the first element is the candidate's
  potential ISBN if available, otherwise its title).
  """
  @type pipeline_result ::
          {:ok, %{resolved: [Stacks.Books.Book.t()], rejected: [{String.t(), atom()}]}}
          | {:error, term()}

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
    analyze(%{image_url: image_url}, context)
  end

  def run_pipeline(%{image_b64: image_b64} = context) do
    analyze(%{image: image_b64}, context)
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
        {:error, :isbn_not_found}

      {:ok, %{"classification" => "CLASSIFICATION_RESULT_BOOK", "books" => books} = resp}
      when is_list(books) ->
        Logger.info("Moderation: /analyze returned #{length(books)} candidate(s)")
        # Propagate `model_used` so downstream can tell barcode-sourced
        # (local_ocr) ISBNs apart from VLM-extracted ones. The fast-path
        # metadata skip is only safe when the source is local_ocr — the
        # VLM can produce strings that happen to pass the ISBN-13 check
        # digit but aren't real books, so we don't trust it unilaterally.
        context_with_source =
          Map.put(context, :vision_model_used, Map.get(resp, "model_used"))

        resolve_and_store_all(books, context_with_source)

      {:ok, %{"classification" => _}} ->
        {:error, :not_a_book}

      error ->
        error
    end
  end

  # Expands compound candidates where the vision model joined multiple book titles
  # with " OR " (e.g. "Things I Don't Want to Know OR The Cost of Living").
  # Each part becomes its own candidate with the same author/raw_text.
  defp expand_compound_candidates(candidates) do
    Enum.flat_map(candidates, fn candidate ->
      title = candidate["title"] || ""

      case String.split(title, ~r/\s+OR\s+/, parts: 2) do
        [part1, part2] ->
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
    expanded = expand_compound_candidates(candidates)
    concurrency = max(length(expanded), 1)

    outcomes =
      expanded
      |> Enum.with_index(1)
      |> Task.async_stream(
        fn {candidate, idx} -> resolve_and_store(candidate, idx, context) end,
        # Same upper bound as run_pipeline's Task.await_many — matches
        # the Modal/Open Library client receive_timeout ceilings. A
        # genuinely slow candidate should not kill the task.
        timeout: 210_000,
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

    resolved = for {:resolved, book} <- outcomes, do: book
    rejected = for {:rejected, candidate_id, reason} <- outcomes, do: {candidate_id, reason}

    case resolved do
      [] -> {:error, :isbn_not_found}
      _ -> {:ok, %{resolved: resolved, rejected: rejected}}
    end
  end

  defp resolve_and_store(candidate, idx, context) do
    case resolve_candidate(candidate, idx) do
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

  defp resolve_candidate(%{"potential_isbns" => [isbn | _]} = _candidate, idx)
       when is_binary(isbn) and isbn != "" do
    Logger.info("Moderation: candidate #{idx} has direct ISBN #{isbn}")
    {:ok, isbn, nil}
  end

  defp resolve_candidate(candidate, idx) do
    title = candidate["title"]
    author = candidate["author"]
    raw_text = candidate["raw_text"]

    Logger.info(
      "Moderation: candidate #{idx} has no ISBN, searching (title=#{inspect(title)}, author=#{inspect(author)}, raw_text=#{inspect(raw_text)})"
    )

    case title_fallback(title, author, raw_text) do
      {:ok, isbn, metadata} -> {:ok, isbn, metadata}
      error -> error
    end
  end

  defp title_fallback(nil, _author, _raw_text), do: {:error, :isbn_not_found}
  defp title_fallback("", _author, _raw_text), do: {:error, :isbn_not_found}

  defp title_fallback(title, author, raw_text) do
    case ISBNResolver.search_by_title(title, author, raw_text) do
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

  defp determine_visibility_tier(bisac_codes) do
    adult_codes = ["FIC005000", "FIC027000", "FIC069000"]

    if Enum.any?(bisac_codes, &(&1 in adult_codes)) do
      "age_gated"
    else
      "public"
    end
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

  defp build_book_attrs(isbn, metadata, used_fast_path, context) do
    subjects = metadata[:subjects] || []
    bisac_codes = subjects_to_bisac(subjects)

    base_attrs = %{
      "isbn" => isbn,
      "title" => derive_title(isbn, metadata, used_fast_path),
      "subjects" => subjects,
      "bisac_codes" => bisac_codes,
      "visibility_tier" => determine_visibility_tier(bisac_codes),
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

  defp subjects_to_bisac(subjects) do
    subject_to_bisac_map = %{
      "fiction" => "FIC000000",
      "mystery" => "FIC022000",
      "science fiction" => "FIC028000",
      "fantasy" => "FIC009000",
      "romance" => "FIC027000",
      "biography" => "BIO000000",
      "history" => "HIS000000",
      "self-help" => "SEL000000",
      "children" => "JUV000000"
    }

    subjects
    |> Enum.map(fn s -> Map.get(subject_to_bisac_map, String.downcase(s)) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end
