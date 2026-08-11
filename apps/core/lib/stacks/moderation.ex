defmodule Stacks.Moderation do
  @moduledoc """
      Moderation pipeline for uploaded book images: is_book? → extract_all →
      store (resolve ISBNs, store each book as `public`). Age-gating is NOT
      decided here — only a human marks a book adults-only.

      Sidecar contract: POST /classify → `{classification, confidence,
      model_used}`; POST /extract → `{books: [{title, author, potential_isbns,
      raw_text, confidence}], model_used}`. Context carries `image_url`
      (preferred, presigned) or `image_b64` (legacy).
  """

  require Logger

  alias Stacks.AI.Client, as: AIClient
  alias Stacks.AI.VisionError
  alias Stacks.Books
  alias Stacks.Books.ISBN
  alias Stacks.Books.ISBNResolver
  alias Stacks.Workers.EnrichBookJob

  @typedoc """
    Closed set of reasons the pipeline fails, following the convention
    `Stacks.Books.ISBNResolver.error_reason/0` documents: the underlying client's
    closed set, extended with the two determinations this layer makes itself.

    `:not_a_book` and `:isbn_not_found` are conclusions about the image, so the
    worker cancels on them. Everything else is a `Stacks.AI.VisionError.t/0` and
    carries its own determination.

    `:resolver_unavailable` is the exception that proves the rule: it is a
    conclusion about neither the image nor the vision service, but about Open
    Library / Google Books. It deliberately stays OUTSIDE
    `Stacks.AI.VisionError.t/0` so the routing below treats it as a fault — which
    is what it is.

    Adding a reason here means deciding, in `Stacks.Workers.IdentifyBookJob`,
    whether it is a determination or a fault: `classify_failure/1` routes it, and
    `rejection_token/1` names what the reader is told. Neither guesses — a reason
    outside `Stacks.AI.VisionError.t/0` is retried and reported as
    `processing_failed`, which is the safe answer, not a silent one.
  """
  @type failure_reason ::
          Stacks.AI.VisionError.t()
          | :not_a_book
          | :isbn_not_found
          | :resolver_unavailable

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
      Runs the full pipeline for one image. `context` needs `image_url`
      (preferred) or `image_b64`, plus `user_id`/`image_id` for logging.
      Returns `{:ok, %{resolved: books, rejected: [{candidate_id, reason}]}}`
      when at least one book resolved — `rejected` surfaces per-candidate
      failures in multi-book images for observability — or `{:error, reason}`
      when nothing resolved or the image is not a book.
  """
  @spec run_pipeline(map()) :: pipeline_result()
  def run_pipeline(%{image_url: image_url} = context) do
    analyze(build_payload(%{image_url: image_url}, context), context)
  end

  def run_pipeline(%{image_b64: image_b64} = context) do
    analyze(build_payload(%{image: image_b64}, context), context)
  end

  defp build_payload(base, context) do
    case Map.get(context, :excluded_books) do
      list when is_list(list) and list != [] -> Map.put(base, :excluded_books, list)
      _ -> base
    end
  end

  defp analyze(payload, context) do
    case AIClient.call_vision("analyze", payload) do
      {:ok, %{"classification" => "CLASSIFICATION_RESULT_BOOK", "books" => []}} ->
        emit_classification(:book)
        {:error, :isbn_not_found}

      {:ok, %{"classification" => "CLASSIFICATION_RESULT_BOOK", "books" => books} = resp}
      when is_list(books) ->
        emit_classification(:book)
        Logger.info("Moderation: /analyze returned #{length(books)} candidate(s)")

        context_with_source =
          Map.put(context, :vision_model_used, Map.get(resp, "model_used"))

        resolve_and_store_all(books, context_with_source)

      {:ok, %{"classification" => classification}} ->
        emit_classification(classification_outcome(classification))
        {:error, :not_a_book}

      {:error, reason} ->
        {:error, reason}

      {:ok, other} ->
        Logger.error(
          "Moderation: /analyze returned an unrecognised response shape " <>
            "(keys: #{inspect(other |> Map.keys() |> Enum.sort())})"
        )

        {:error, VisionError.from_transport(:unrecognised_response)}
    end
  end

  defp emit_classification(outcome) do
    :telemetry.execute([:stacks, :moderation, :classification], %{count: 1}, %{outcome: outcome})
  end

  defp classification_outcome("CLASSIFICATION_RESULT_BOOK"), do: :book
  defp classification_outcome("CLASSIFICATION_RESULT_NOT_BOOK"), do: :not_a_book
  defp classification_outcome("CLASSIFICATION_RESULT_AMBIGUOUS"), do: :ambiguous
  defp classification_outcome(_), do: :unknown

  defp expand_compound_candidates(candidates) do
    Enum.flat_map(candidates, fn candidate ->
      title = candidate["title"] || ""

      case String.split(title, ~r/\s+OR\s+/, parts: 2) do
        [part1, part2] ->
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
      [] -> {:error, no_resolution_reason(outcomes)}
      _ -> {:ok, %{resolved: resolved, rejected: rejected}}
    end
  end

  defp no_resolution_reason([]), do: :isbn_not_found

  defp no_resolution_reason(outcomes) do
    if Enum.all?(outcomes, &match?({:rejected, _id, :resolver_unavailable}, &1)),
      do: :resolver_unavailable,
      else: :isbn_not_found
  end

  @resolution_reasons [
    :isbn_not_found,
    :low_confidence,
    :invalid_book,
    :resolver_unavailable,
    :store_failed,
    :task_exit
  ]

  defp emit_resolution_outcome({:resolved, _book}), do: emit_resolution(:resolved)

  defp emit_resolution_outcome({:rejected, _candidate_id, reason}),
    do: emit_resolution(whitelist_resolution_reason(reason))

  defp emit_resolution(outcome) do
    :telemetry.execute([:stacks, :moderation, :isbn_resolution], %{count: 1}, %{outcome: outcome})
  end

  defp whitelist_resolution_reason(reason) when reason in @resolution_reasons, do: reason
  defp whitelist_resolution_reason(_), do: :other

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

  defp normalise_isbn(value) when is_binary(value), do: ISBN.canonical_isbn13(value)

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

  @nullish_author_values ["null", "none", "n/a", "unknown", ""]

  defp normalise_author(value) when is_binary(value) do
    if String.downcase(String.trim(value)) in @nullish_author_values, do: nil, else: value
  end

  defp normalise_author(_), do: nil

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

      {:error, :unavailable} ->
        Logger.warning(
          "Moderation: title search for '#{title}' could not be completed — " <>
            "OL/GB unavailable, not recording an absence"
        )

        {:error, :resolver_unavailable}
    end
  end

  defp store_book(isbn, prefetched_metadata, context) do
    Stacks.Telemetry.phase(
      :persistence,
      %{upload_id: Map.get(context, :image_id), isbn: isbn},
      fn ->
        isbn
        |> resolve_metadata(prefetched_metadata, context)
        |> persist(isbn, context)
      end
    )
  end

  defp persist({:ok, metadata, used_fast_path}, isbn, context) do
    case Books.find_existing(isbn) do
      nil -> Books.create(build_book_attrs(isbn, metadata, used_fast_path, context))
      existing -> {:ok, existing}
    end
  end

  defp persist({:error, :resolver_unavailable}, isbn, _context) do
    case Books.find_existing(isbn) do
      nil -> {:error, :resolver_unavailable}
      existing -> {:ok, existing}
    end
  end

  defp resolve_metadata(_isbn, prefetched_metadata, _context)
       when not is_nil(prefetched_metadata) do
    {:ok, prefetched_metadata, false}
  end

  defp resolve_metadata(isbn, _prefetched_metadata, context) do
    if fast_path?(isbn, context) do
      enqueue_metadata_enrichment(isbn)
      {:ok, %{}, true}
    else
      case Books.resolve_isbn(isbn) do
        {:ok, data} -> {:ok, data, false}
        {:error, reason} -> resolver_outcome(reason)
      end
    end
  end

  defp resolver_outcome(reason) do
    if ISBNResolver.resolver_error?(reason) do
      case ISBNResolver.determination(reason) do
        :not_found -> {:ok, %{}, false}
        :unavailable -> {:error, :resolver_unavailable}
      end
    else
      Logger.warning(
        "Moderation: ISBN resolver returned #{inspect(reason)}, which is outside " <>
          "ISBNResolver.error_reason/0 — treating as unavailable"
      )

      {:error, :resolver_unavailable}
    end
  end

  defp fast_path?(isbn, context) do
    context[:vision_model_used] == "local_ocr" and ISBN.valid_isbn_checksum?(isbn)
  end

  defp build_book_attrs(isbn, metadata, used_fast_path, context) do
    base_attrs = %{
      "isbn" => isbn,
      "title" => derive_title(isbn, metadata, used_fast_path),
      "open_library_id" => metadata[:open_library_id],
      "google_books_id" => metadata[:google_books_id],
      "verification_source" => if(used_fast_path, do: "barcode_unverified"),
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
