defmodule Stacks.Moderation do
  @moduledoc """
  Moderation pipeline for uploaded book images.

  Runs a 4-step pipeline:
  1. is_book? — vision model checks if image contains a book
  2. extract_isbn — vision model extracts ISBN from the spine/cover
  3. classify_subject — BISAC subject classification from book subjects
  4. store_with_tier — stores book with appropriate visibility_tier
  """

  require Logger

  alias Stacks.AI.Client, as: AIClient
  alias Stacks.Books

  @doc """
  Runs the full moderation pipeline for an uploaded image.

  Returns `{:ok, book}` on success, `{:error, reason}` on failure.
  """
  @spec run_pipeline(map()) :: {:ok, Stacks.Books.Book.t()} | {:error, term()}
  def run_pipeline(%{image_url: image_url} = context) do
    with {:ok, :is_book} <- check_is_book(image_url),
         {:ok, isbn} <- extract_isbn(image_url),
         {:ok, subjects} <- classify_subjects(isbn, context) do
      store_with_tier(isbn, subjects, context)
    end
  end

  defp check_is_book(image_url) do
    case AIClient.call_vision("is_book", %{image_url: image_url}) do
      {:ok, %{"is_book" => true}} -> {:ok, :is_book}
      {:ok, _} -> {:error, :not_a_book}
      error -> error
    end
  end

  defp extract_isbn(image_url) do
    case AIClient.call_vision("extract_isbn", %{image_url: image_url}) do
      {:ok, %{"isbn" => isbn}} when is_binary(isbn) and isbn != "" ->
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
        {:ok, %{subjects: subjects, bisac_codes: bisac_codes}}

      _ ->
        {:ok, %{subjects: [], bisac_codes: []}}
    end
  end

  defp store_with_tier(isbn, subjects_data, context) do
    visibility_tier = determine_visibility_tier(subjects_data.bisac_codes)

    attrs =
      Map.merge(context[:book_attrs] || %{}, %{
        "isbn" => isbn,
        "subjects" => subjects_data.subjects,
        "bisac_codes" => subjects_data.bisac_codes,
        "visibility_tier" => visibility_tier
      })

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
