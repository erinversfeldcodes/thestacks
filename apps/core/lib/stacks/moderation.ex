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

  @doc """
  Runs the full moderation pipeline for an uploaded image.

  Expects `context` to include one of:
  - `image_url` — presigned URL to the image in object storage (preferred)
  - `image_b64` — base64-encoded image bytes (legacy/backwards compat)

  Plus `user_id`, `image_id` for logging/context.

  Returns `{:ok, [Book.t()]}` on success (one or more books identified),
  or `{:error, reason}` on failure.
  """
  @spec run_pipeline(map()) :: {:ok, [Stacks.Books.Book.t()]} | {:error, term()}
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

      {:ok, %{"classification" => "CLASSIFICATION_RESULT_BOOK", "books" => books}}
      when is_list(books) ->
        Logger.info("Moderation: /analyze returned #{length(books)} candidate(s)")
        resolve_and_store_all(books, context)

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
  # create/find the book. Returns {:ok, [books]} with whatever could be resolved;
  # fails only if NONE of the candidates resolve.
  #
  # Candidates are resolved concurrently via `Task.async_stream`. Each
  # candidate triggers an Open Library (sometimes Google Books) HTTP
  # lookup plus DB work; sequential processing of 2+ candidates easily
  # adds 0.5–1.5s to the overall pipeline. With concurrency, total wait
  # is bounded by the slowest candidate rather than their sum. Failures
  # in one candidate don't affect the others — `resolve_and_store/3`
  # returns `[]` on failure which flat-maps away.
  defp resolve_and_store_all(candidates, context) do
    expanded = expand_compound_candidates(candidates)
    concurrency = max(length(expanded), 1)

    books =
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
      |> Enum.flat_map(fn
        {:ok, result} ->
          result

        {:exit, reason} ->
          Logger.warning("Moderation: candidate task exited: #{inspect(reason)}")
          []
      end)

    case books do
      [] -> {:error, :isbn_not_found}
      _ -> {:ok, books}
    end
  end

  defp resolve_and_store(candidate, idx, context) do
    case resolve_candidate(candidate, idx) do
      {:ok, isbn, metadata} ->
        case store_book(isbn, metadata, context) do
          {:ok, book} -> [book]
          _ -> []
        end

      {:error, reason} ->
        Logger.warning("Moderation: candidate #{idx} failed to resolve: #{inspect(reason)}")
        []
    end
  end

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
    metadata =
      if prefetched_metadata do
        prefetched_metadata
      else
        case Books.resolve_isbn(isbn) do
          {:ok, data} -> data
          _ -> %{}
        end
      end

    subjects = metadata[:subjects] || []
    bisac_codes = subjects_to_bisac(subjects)
    visibility_tier = determine_visibility_tier(bisac_codes)

    base_attrs = %{
      "isbn" => isbn,
      "title" => metadata[:title],
      "subjects" => subjects,
      "bisac_codes" => bisac_codes,
      "visibility_tier" => visibility_tier,
      "description" => metadata[:description],
      "cover_image_url" => metadata[:cover_image_url],
      "publisher" => metadata[:publisher],
      "publication_year" => metadata[:publication_year],
      "page_count" => metadata[:page_count],
      "author" => metadata[:author]
    }

    attrs = Map.merge(base_attrs, context[:book_attrs] || %{})

    case Books.find_existing(isbn) do
      nil -> Books.create(attrs)
      existing -> {:ok, existing}
    end
  end

  defp determine_visibility_tier(bisac_codes) do
    adult_codes = ["FIC005000", "FIC027000", "FIC069000"]

    if Enum.any?(bisac_codes, &(&1 in adult_codes)) do
      "age_gated"
    else
      "public"
    end
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
