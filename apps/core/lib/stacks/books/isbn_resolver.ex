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
