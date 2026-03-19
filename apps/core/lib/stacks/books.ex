defmodule Stacks.Books do
  @moduledoc """
  Books context — book creation, discovery, and ISBN resolution.

  In the works/editions model:
  - A **book** (work) is the logical entity: "Circe" by Madeline Miller
  - A **book_edition** is a specific ISBN/format: "Circe, Bloomsbury paperback, 9780316556347"

  The ISBN hard gate is enforced here: every edition must have a verified ISBN.
  """

  # Ecto.Multi uses an opaque MapSet internally; dialyzer cannot resolve the
  # opaque subterms after Multi.new() and fires call_without_opaque on every
  # chained call. This is a known false positive.
  @dialyzer :no_opaque

  import Ecto.Query

  alias Core.Repo
  alias Ecto.Multi
  alias Stacks.Books.{Author, Book, BookEdition, UploadedImage}
  alias Stacks.Books.ISBNResolver
  alias Stacks.Events
  alias Stacks.Workers.IdentifyBookJob

  @doc """
  Returns a book (work) by ID with the author and editions preloaded.
  """
  @spec get_book_detail(binary()) :: Book.t() | nil
  def get_book_detail(id) do
    Book
    |> where([b], b.id == ^id)
    |> preload([:author, :editions])
    |> Repo.one()
  end

  @doc """
  Returns the primary edition for a book, or the first edition as fallback.
  """
  @spec primary_edition(Book.t()) :: BookEdition.t() | nil
  def primary_edition(%Book{editions: editions}) when is_list(editions) do
    Enum.find(editions, & &1.is_primary) || List.first(editions)
  end

  def primary_edition(%Book{id: book_id}) do
    BookEdition
    |> where([e], e.book_id == ^book_id)
    |> order_by([e], desc: e.is_primary)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Finds an existing book (work) by ISBN — looks up the edition, returns the parent work.
  """
  @spec find_existing(String.t()) :: Book.t() | nil
  def find_existing(isbn) do
    BookEdition
    |> where([e], e.isbn == ^isbn)
    |> preload(book: [:author, :editions])
    |> Repo.one()
    |> case do
      nil -> nil
      edition -> edition.book
    end
  end

  @doc """
  Creates a book (work) with its first edition from attributes.
  Requires `:isbn` and `:title`.
  """
  @spec create(map()) :: {:ok, Book.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    book_changeset =
      %Book{}
      |> Book.changeset(attrs)
      |> maybe_create_author(attrs)

    Multi.new()
    |> Multi.insert(:book, book_changeset)
    |> Multi.insert(:edition, fn %{book: book} ->
      %BookEdition{}
      |> BookEdition.changeset(%{
        "isbn" => attrs["isbn"],
        "book_id" => book.id,
        "format_label" => attrs["format_label"],
        "cover_image_url" => attrs["cover_image_url"],
        "page_count" => attrs["page_count"],
        "publisher" => attrs["publisher"],
        "publication_year" => attrs["publication_year"],
        "open_library_id" => attrs["open_library_id"],
        "google_books_id" => attrs["google_books_id"],
        "is_primary" => true
      })
    end)
    |> Multi.run(:emit_event, fn _repo, %{book: book, edition: edition} ->
      Events.emit_safe(%{
        event_type: "book.created",
        aggregate_type: "book",
        aggregate_id: book.id,
        payload: %{isbn: edition.isbn, title: book.title}
      })

      {:ok, book}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{book: book, edition: edition}} ->
        {:ok, %{book | editions: [edition]}}

      {:error, :book, changeset, _} ->
        {:error, changeset}

      {:error, :edition, changeset, _} ->
        {:error, changeset}

      {:error, _, reason, _} ->
        {:error, reason}
    end
  end

  @doc """
  Resolves book metadata from an ISBN via Open Library / Google Books,
  then creates the book (work) and edition records.
  """
  @spec create_from_isbn(String.t()) ::
          {:ok, Book.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def create_from_isbn(isbn) do
    with :ok <- validate_isbn_format(isbn),
         {:ok, metadata} <- ISBNResolver.resolve(isbn),
         {:ok, author} <- find_or_create_author(metadata[:author]) do
      isbn |> build_book_attrs(metadata, author) |> create()
    end
  end

  defp validate_isbn_format(isbn) do
    cs =
      BookEdition.changeset(%BookEdition{}, %{"isbn" => isbn, "book_id" => Ecto.UUID.generate()})

    if Keyword.has_key?(cs.errors, :isbn) do
      {:error, cs}
    else
      :ok
    end
  end

  @doc """
  Resolves book metadata from an ISBN using Open Library / Google Books.
  Delegates to the internal ISBNResolver. Use this instead of calling
  ISBNResolver directly from other contexts.
  """
  @spec resolve_isbn(String.t()) :: {:ok, map()} | {:error, :not_found}
  def resolve_isbn(isbn) do
    ISBNResolver.resolve(isbn)
  end

  @doc """
  Reads an uploaded file, inserts an `UploadedImage` record, and returns the record
  together with the image bytes base64-encoded.

  Returns `{:ok, {uploaded_image, image_b64}}` or `{:error, reason}`.

  The bytes are passed directly to `upload_and_identify/3` and included in the Oban
  job args so any machine can execute the job without shared filesystem access.
  """
  @spec store_upload(binary(), Plug.Upload.t()) ::
          {:ok, {UploadedImage.t(), String.t()}} | {:error, term()}
  def store_upload(_user_id, %Plug.Upload{path: tmp_path}) do
    case File.read(tmp_path) do
      {:ok, bytes} ->
        now = DateTime.utc_now()

        result =
          %UploadedImage{}
          |> UploadedImage.changeset(%{
            status: "pending",
            uploaded_at: now,
            expires_at: DateTime.add(now, 30, :day)
          })
          |> Repo.insert()

        case result do
          {:ok, image} ->
            Events.emit_safe(%{
              event_type: "image.submitted",
              aggregate_type: "image",
              aggregate_id: image.id,
              payload: %{}
            })

            {:ok, {image, Base.encode64(bytes)}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Enqueues a vision-model identification job for an uploaded image.
  `image_b64` is included in the job args so the worker needs no filesystem access.
  Returns `{:ok, job}` immediately; the job resolves ISBN and creates the book asynchronously.
  """
  @spec upload_and_identify(binary(), binary(), String.t()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def upload_and_identify(user_id, image_id, image_b64) do
    %{user_id: user_id, image_id: image_id, image_b64: image_b64}
    |> IdentifyBookJob.new()
    |> Oban.insert()
  end

  @doc """
  Returns a paginated list of all books (works) with optional search, subject filter,
  and sort order. No ownership data is included — this powers the public
  catalogue endpoint.

  ## Options

    * `:search` — free-text search against `title_tsv` (optional)
    * `:subject` — filter to books containing this subject (optional)
    * `:sort` — one of `"title"`, `"author"`, `"recent"` (default `"title"`)
    * `:page` — 1-based page number (default 1)
    * `:per_page` — items per page (default 24, max 100)

  Returns `{books, total_count}`.
  """
  @spec list_catalogue(keyword()) :: {[Book.t()], non_neg_integer()}
  def list_catalogue(opts \\ []) do
    search = Keyword.get(opts, :search)
    subject = Keyword.get(opts, :subject)
    sort = Keyword.get(opts, :sort, "title")
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = min(max(Keyword.get(opts, :per_page, 24), 1), 100)
    offset = (page - 1) * per_page

    base =
      Book
      |> preload([:author, :editions])

    filtered =
      base
      |> maybe_search(search)
      |> maybe_filter_subject(subject)

    total = Repo.aggregate(filtered, :count)

    books =
      filtered
      |> apply_sort(sort)
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()

    {books, total}
  end

  defp maybe_search(query, nil), do: query
  defp maybe_search(query, ""), do: query

  defp maybe_search(query, search) do
    safe_query = String.replace(search, ~r/[^\w\s]/, "")

    where(
      query,
      [b],
      fragment("title_tsv @@ plainto_tsquery('english', ?)", ^safe_query)
    )
  end

  defp maybe_filter_subject(query, nil), do: query
  defp maybe_filter_subject(query, ""), do: query

  defp maybe_filter_subject(query, subject) do
    where(query, [b], ^subject in b.subjects)
  end

  defp apply_sort(query, "author") do
    query
    |> join(:left, [b], a in assoc(b, :author), as: :author_sort)
    |> order_by([b, author_sort: a], asc_nulls_last: a.name, asc: b.title)
  end

  defp apply_sort(query, "recent") do
    order_by(query, [b], desc: b.created_at)
  end

  defp apply_sort(query, _title) do
    order_by(query, [b], asc: b.title)
  end

  @doc """
  Full-text search on book titles using the stored `title_tsv` tsvector column.
  Returns up to `limit` results (default 20).
  """
  @spec search_books(String.t(), keyword()) :: [Book.t()]
  def search_books(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    safe_query = String.replace(query, ~r/[^\w\s]/, "")

    Book
    |> where(
      [b],
      fragment(
        "title_tsv @@ plainto_tsquery('english', ?)",
        ^safe_query
      )
    )
    |> preload([:author, :editions])
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Update cover_image_url on a book edition after the vision sidecar confirms the association.
  Emits a book.cover_confirmed event.
  Returns {:ok, edition} or {:error, reason}.
  """
  @spec confirm_cover_association(String.t(), String.t()) ::
          {:ok, BookEdition.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def confirm_cover_association(edition_id, cover_url) do
    case Repo.get(BookEdition, edition_id) do
      nil ->
        {:error, :not_found}

      edition ->
        changeset = BookEdition.changeset(edition, %{cover_image_url: cover_url})

        case Repo.update(changeset) do
          {:ok, updated} ->
            Events.emit(%{
              event_type: "book.cover_confirmed",
              aggregate_type: "book_edition",
              aggregate_id: updated.id,
              payload: %{cover_image_url: cover_url},
              metadata: %{actor: "vision_sidecar"}
            })

            {:ok, updated}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  defp maybe_create_author(changeset, %{"author" => name}) when is_binary(name) and name != "" do
    case find_or_create_author(name) do
      {:ok, author} -> Ecto.Changeset.put_change(changeset, :author_id, author.id)
      _ -> changeset
    end
  end

  defp maybe_create_author(changeset, _attrs), do: changeset

  defp find_or_create_author(nil), do: {:ok, nil}
  defp find_or_create_author(""), do: {:ok, nil}

  defp find_or_create_author(name) when is_binary(name) do
    case Repo.get_by(Author, name: name) do
      nil ->
        %Author{}
        |> Author.changeset(%{name: name})
        |> Repo.insert()

      author ->
        {:ok, author}
    end
  end

  defp build_book_attrs(isbn, metadata, author) do
    base = %{
      "isbn" => isbn,
      "title" => metadata[:title] || "Unknown Title",
      "description" => metadata[:description],
      "cover_image_url" => metadata[:cover_image_url],
      "publisher" => metadata[:publisher],
      "publication_year" => metadata[:publication_year],
      "page_count" => metadata[:page_count],
      "subjects" => metadata[:subjects] || [],
      "open_library_id" => metadata[:open_library_id],
      "google_books_id" => metadata[:google_books_id]
    }

    case author do
      nil -> base
      author -> Map.put(base, "author_id", author.id)
    end
  end
end
