defmodule Stacks.Books do
  @moduledoc """
  Books context — book creation, discovery, and ISBN resolution.

  All books must have a verified ISBN. The ISBN hard gate is enforced here:
  `create/1` requires an `:isbn` field. `create_from_isbn/1` resolves metadata
  from Open Library / Google Books before inserting.
  """

  import Ecto.Query

  alias Core.Repo
  alias Ecto.Multi
  alias Stacks.Books.{Author, Book, UploadedImage}
  alias Stacks.Books.ISBNResolver
  alias Stacks.Events
  alias Stacks.Workers.IdentifyBookJob

  @doc """
  Returns a book by ID with the author preloaded.
  """
  @spec get_book_detail(binary()) :: Book.t() | nil
  def get_book_detail(id) do
    Book
    |> where([b], b.id == ^id)
    |> preload(:author)
    |> Repo.one()
  end

  @doc """
  Finds an existing book by ISBN.
  """
  @spec find_existing(String.t()) :: Book.t() | nil
  def find_existing(isbn) do
    Repo.get_by(Book, isbn: isbn)
  end

  @doc """
  Creates a book from attributes. Requires `:isbn` and `:title`.
  """
  @spec create(map()) :: {:ok, Book.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    changeset =
      %Book{}
      |> Book.changeset(attrs)
      |> maybe_create_author(attrs)

    Multi.new()
    |> Multi.insert(:book, changeset)
    |> Multi.run(:emit_event, fn _repo, %{book: book} ->
      Events.emit_safe(%{
        event_type: "book.created",
        aggregate_type: "book",
        aggregate_id: book.id,
        payload: %{isbn: book.isbn, title: book.title}
      })

      {:ok, book}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{book: book}} -> {:ok, book}
      {:error, :book, changeset, _} -> {:error, changeset}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  @doc """
  Resolves book metadata from an ISBN via Open Library / Google Books,
  then creates the book and author records.
  """
  @spec create_from_isbn(String.t()) ::
          {:ok, Book.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def create_from_isbn(isbn) do
    with {:ok, metadata} <- ISBNResolver.resolve(isbn),
         {:ok, author} <- find_or_create_author(metadata[:author]) do
      isbn |> build_book_attrs(metadata, author) |> create()
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
  Persists an uploaded file to the configured upload directory and inserts an
  `UploadedImage` record. Returns `{:ok, uploaded_image}` or `{:error, reason}`.

  The storage path is relative (e.g. `"abc123.jpg"`). The URL the vision sidecar
  uses to fetch the image is built by `IdentifyBookJob` from `:storage_base_url`.
  In production, replace this with a Tigris/S3 upload.
  """
  @spec store_upload(binary(), Plug.Upload.t()) ::
          {:ok, UploadedImage.t()} | {:error, term()}
  def store_upload(_user_id, %Plug.Upload{filename: filename, path: tmp_path}) do
    image_id = Ecto.UUID.generate()
    ext = Path.extname(filename)
    upload_dir = Application.get_env(:core, :upload_dir, "priv/static/uploads")
    File.mkdir_p!(upload_dir)
    dest = Path.join(upload_dir, "#{image_id}#{ext}")

    case File.copy(tmp_path, dest) do
      {:ok, _} ->
        now = DateTime.utc_now()

        %UploadedImage{id: image_id}
        |> UploadedImage.changeset(%{
          storage_path: "#{image_id}#{ext}",
          status: "pending",
          uploaded_at: now,
          expires_at: DateTime.add(now, 30, :day)
        })
        |> Repo.insert()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Enqueues a vision-model identification job for an uploaded image.
  Returns `{:ok, job}` immediately; the job resolves ISBN and creates the book asynchronously.
  """
  @spec upload_and_identify(binary(), binary()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def upload_and_identify(user_id, image_id) do
    %{user_id: user_id, image_id: image_id}
    |> IdentifyBookJob.new()
    |> Oban.insert()
  end

  @doc """
  Full-text search on book titles using the stored `title_tsv` tsvector column.
  Returns up to `limit` results (default 20).
  """
  @spec search_books(String.t(), keyword()) :: [Book.t()]
  def search_books(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    safe_query = String.replace(query, ~r/[^\w\s]/, "") <> ":*"

    Book
    |> where(
      [b],
      fragment(
        "title_tsv @@ to_tsquery('english', ?)",
        ^safe_query
      )
    )
    |> preload(:author)
    |> limit(^limit)
    |> Repo.all()
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
