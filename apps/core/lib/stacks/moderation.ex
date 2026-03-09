defmodule Stacks.Moderation do
  @moduledoc """
  Moderation pipeline for uploaded book images.

  Runs a 4-step pipeline:
  1. is_book? — vision model checks if image contains a book
  2. extract_isbn — vision model extracts ISBN from the spine/cover
  3. classify_subject — BISAC subject classification from book subjects
  4. store_with_tier — stores book with appropriate visibility_tier

  Sidecar API contract:
  - POST /classify  → %{"classification" => "book"|"not_book"|"ambiguous", "confidence" => float, "model_used" => str}
  - POST /extract   → %{"title" => str|nil, "author" => str|nil, "potential_isbns" => [str], "raw_text" => str|nil, "model_used" => str, "confidence" => float}

  Both endpoints expect base64-encoded image data (not image URLs).
  """

  require Logger

  alias Stacks.AI.Client, as: AIClient
  alias Stacks.Books

  @doc """
  Runs the full moderation pipeline for an uploaded image.

  Expects `context` to include:
  - `image_b64` — base64-encoded image bytes
  - `user_id`, `image_id` — for logging/context

  Returns `{:ok, book}` on success, `{:error, reason}` on failure.
  """
  @spec run_pipeline(map()) :: {:ok, Stacks.Books.Book.t()} | {:error, term()}
  def run_pipeline(%{image_b64: image_b64} = context) do
    with {:ok, :is_book} <- check_is_book(image_b64),
         {:ok, isbn} <- extract_isbn(image_b64),
         {:ok, subjects} <- classify_subjects(isbn, context) do
      store_with_tier(isbn, subjects, context)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_is_book(image_b64) do
    case AIClient.call_vision("is_book", %{image: image_b64}) do
      {:ok, %{"classification" => "book"}} -> {:ok, :is_book}
      {:ok, %{"classification" => _}} -> {:error, :not_a_book}
      error -> error
    end
  end

  defp extract_isbn(image_b64) do
    case AIClient.call_vision("extract_isbn", %{images: [image_b64]}) do
      {:ok, %{"potential_isbns" => [isbn | _]}} when is_binary(isbn) and isbn != "" ->
        {:ok, isbn}

      {:ok, _} ->
        {:error, :isbn_not_found}

      error ->
        error
    end
  end

  defp classify_subjects(isbn, _context) do
    case Books.resolve_isbn(isbn) do
      {:ok, metadata} ->
        subjects = metadata[:subjects] || []
        bisac_codes = subjects_to_bisac(subjects)
        {:ok, metadata |> Map.put(:subjects, subjects) |> Map.put(:bisac_codes, bisac_codes)}

      _ ->
        {:ok, %{subjects: [], bisac_codes: []}}
    end
  end

  defp store_with_tier(isbn, metadata, context) do
    visibility_tier = determine_visibility_tier(metadata.bisac_codes)

    # ISBNResolver metadata is the base; context book_attrs can override any field
    base_attrs = %{
      "isbn" => isbn,
      "title" => metadata[:title],
      "subjects" => metadata.subjects,
      "bisac_codes" => metadata.bisac_codes,
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
