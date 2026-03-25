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

  require Logger

  import Ecto.Changeset
  import Ecto.Query

  alias Core.Repo
  alias Ecto.Multi
  alias Stacks.Books.{Author, Book, BookEdition, UploadedImage}
  alias Stacks.Books.ISBNResolver
  alias Stacks.Events
  alias Stacks.Shelving
  alias Stacks.Workers.IdentifyBookJob

  # ── Field lists for changesets (moved from schemas) ──────────────────────

  @book_required_fields [:title]
  @book_optional_fields [
    :author_id,
    :description,
    :language,
    :subjects,
    :bisac_codes,
    :visibility_tier
  ]

  @author_cast_fields [:name, :bio, :website_url, :rss_feed_url, :open_library_id]

  @edition_required_fields [:isbn, :book_id]
  @edition_optional_fields [
    :format_label,
    :cover_image_url,
    :page_count,
    :publisher,
    :publication_year,
    :open_library_id,
    :google_books_id,
    :is_primary
  ]

  @image_cast_fields [
    :storage_path,
    :status,
    :rejection_reason,
    :uploaded_at,
    :expires_at,
    :book_id,
    :book_edition_id,
    :book_ids
  ]

  @valid_image_statuses ~w(pending resolved rejected)

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
  Returns the community read count for a book from the wh.mart_community_read_count
  analytics view. Returns 0 if the mart does not yet exist or the book has no entry.
  """
  @spec community_read_count(binary()) :: non_neg_integer()
  def community_read_count(book_id) do
    result =
      Repo.query(
        "SELECT read_count FROM wh.mart_community_read_count WHERE book_id = $1 LIMIT 1",
        [book_id]
      )

    case result do
      {:ok, %{rows: [[count]]}} -> count
      _ -> 0
    end
  rescue
    e ->
      require Logger
      Logger.warning("community_read_count: unexpected error for book #{book_id}: #{inspect(e)}")
      0
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
      |> book_changeset(attrs)
      |> maybe_create_author(attrs)

    Multi.new()
    |> Multi.insert(:book, book_changeset)
    |> Multi.insert(:edition, fn %{book: book} ->
      %BookEdition{}
      |> book_edition_changeset(%{
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
      book_edition_changeset(%BookEdition{}, %{"isbn" => isbn, "book_id" => Ecto.UUID.generate()})

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
  Reads an uploaded file, stores it in object storage, inserts an `UploadedImage`
  record with the `storage_path` set, and returns the record.

  Returns `{:ok, uploaded_image}` or `{:error, reason}`.

  The storage key is persisted on the record so any machine can retrieve the
  image via a presigned URL — no shared filesystem or base64 in job args needed.
  """
  @spec store_upload(binary(), Plug.Upload.t()) ::
          {:ok, UploadedImage.t()} | {:error, term()}
  def store_upload(_user_id, %Plug.Upload{path: tmp_path}) do
    image_id = Ecto.UUID.generate()
    storage_key = "uploads/#{image_id}"

    with {:ok, bytes} <- File.read(tmp_path),
         {:ok, _key} <- Stacks.Storage.upload_image(image_id, bytes),
         {:ok, image} <- insert_uploaded_image(image_id, storage_key) do
      Events.emit_safe(%{
        event_type: "image.submitted",
        aggregate_type: "image",
        aggregate_id: image.id,
        payload: %{storage_path: storage_key}
      })

      {:ok, image}
    else
      {:error, reason} ->
        # Clean up stored object if DB insert fails (no-op if upload never happened)
        Stacks.Storage.delete_image(storage_key)
        {:error, reason}
    end
  end

  defp insert_uploaded_image(image_id, storage_key) do
    now = DateTime.utc_now()

    %UploadedImage{id: image_id}
    |> uploaded_image_changeset(%{
      storage_path: storage_key,
      status: "pending",
      uploaded_at: now,
      expires_at: DateTime.add(now, 30, :day)
    })
    |> Repo.insert()
  end

  @doc """
  Enqueues a vision-model identification job for an uploaded image.

  The `storage_key` is included in the job args so the worker can fetch a
  presigned URL at execution time — no base64 blob in the job payload.

  Returns `{:ok, job}` immediately; the job resolves ISBN and creates the book asynchronously.
  """
  @spec upload_and_identify(binary(), binary(), String.t()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def upload_and_identify(user_id, image_id, storage_key) do
    %{user_id: user_id, image_id: image_id, storage_key: storage_key}
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
    viewer = Keyword.get(opts, :viewer, :unauthenticated)

    base =
      Book
      |> preload([:author, :editions])

    filtered =
      base
      |> maybe_search(search)
      |> maybe_filter_subject(subject)
      |> maybe_exclude_age_gated(viewer)

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

  defp maybe_exclude_age_gated(query, :unauthenticated) do
    where(query, [b], b.visibility_tier != "age_gated")
  end

  defp maybe_exclude_age_gated(query, _viewer), do: query

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
        final_url = maybe_store_cover_in_r2(edition.isbn, cover_url)
        changeset = book_edition_changeset(edition, %{cover_image_url: final_url})

        case Repo.update(changeset) do
          {:ok, updated} ->
            Events.emit_safe(%{
              event_type: "book.cover_confirmed",
              aggregate_type: "book_edition",
              aggregate_id: updated.id,
              payload: %{cover_image_url: final_url},
              metadata: %{actor: "vision_sidecar"}
            })

            {:ok, updated}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  defp maybe_store_cover_in_r2(isbn, cover_url) when is_binary(isbn) do
    # Covers are permanent — use a long-lived presigned URL (7 days).
    # In production, R2 public bucket access or CDN would serve these.
    with {:ok, image_data} <- download_cover(cover_url),
         {:ok, storage_key} <- Stacks.Storage.store_cover(isbn, image_data),
         {:ok, r2_url} <- Stacks.Storage.get_image_url(storage_key, 604_800) do
      r2_url
    else
      _ -> cover_url
    end
  end

  defp maybe_store_cover_in_r2(_isbn, cover_url), do: cover_url

  defp download_cover(url) when is_binary(url) do
    req = Finch.build(:get, url)

    case Finch.request(req, Stacks.Finch, receive_timeout: 10_000) do
      {:ok, %Finch.Response{status: 200, body: body}} -> {:ok, body}
      _ -> {:error, :download_failed}
    end
  rescue
    e ->
      Logger.warning("Books: cover download failed for #{url}: #{Exception.message(e)}")
      {:error, :download_failed}
  end

  @doc """
  Searches the platform catalogue for publicly visible books.

  Full-text search is performed against the book title and joined author name.
  An empty query returns a paginated slice of the full catalogue.

  ## Options

    * `:page` — 1-based page number (default 1)
    * `:per_page` / `:limit` — items per page (default 24, max 100)

  Returns `{books_list, total_count}`.
  """
  @spec search_platform(String.t(), keyword()) :: {[map()], non_neg_integer()}
  def search_platform(query, opts \\ []) do
    per_page = min(max(Keyword.get(opts, :per_page, Keyword.get(opts, :limit, 24)), 1), 100)
    page = max(Keyword.get(opts, :page, 1), 1)
    offset = (page - 1) * per_page

    base =
      Book
      |> join(:left, [b], a in Author, on: a.id == b.author_id)
      |> preload([:author, :editions])

    filtered =
      if query == nil or String.trim(query) == "" do
        base
      else
        safe = String.replace(query, ~r/[^\w\s]/, "")

        where(
          base,
          [b, a],
          ilike(b.title, ^"%#{safe}%") or ilike(a.name, ^"%#{safe}%")
        )
      end

    total = Repo.aggregate(filtered, :count)

    books =
      filtered
      |> order_by([b], asc: b.title)
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()

    {books, total}
  end

  @doc """
  Finds books in the platform that are likely the same work as the given title
  and author, using Jaro-Winkler string similarity on both fields combined.

  Returns matches where the combined similarity score exceeds 0.8.
  Each result is a map with `:id`, `:title`, `:author`, `:similarity`.
  """
  @spec find_same_work(String.t(), String.t()) :: [map()]
  def find_same_work(title, author) do
    title_prefix = title |> String.split() |> List.first("") |> String.downcase()
    author_prefix = author |> String.split() |> List.first("") |> String.downcase()

    candidates =
      Book
      |> join(:left, [b], a in Author, on: a.id == b.author_id)
      |> select([b, a], %{id: b.id, title: b.title, author: a.name})
      |> where(
        [b, a],
        ilike(b.title, ^"%#{title_prefix}%") or ilike(a.name, ^"%#{author_prefix}%")
      )
      |> Repo.all()

    candidates
    |> Enum.map(fn %{title: t, author: a} = row ->
      title_sim = jaro_winkler(title, t || "")
      author_sim = jaro_winkler(author, a || "")
      combined = (title_sim + author_sim) / 2.0
      Map.put(row, :similarity, combined)
    end)
    |> Enum.filter(fn %{similarity: s} -> s > 0.8 end)
    |> Enum.sort_by(& &1.similarity, :desc)
  end

  # Jaro-Winkler similarity: jaro + prefix_len * p * (1 - jaro)
  # p = 0.1, prefix length capped at 4.
  defp jaro_winkler(s1, s2) do
    jaro = String.jaro_distance(s1, s2)

    prefix_len =
      [s1, s2]
      |> Enum.map(&String.graphemes/1)
      |> then(fn [g1, g2] ->
        Enum.zip(g1, g2)
        |> Enum.take(4)
        |> Enum.take_while(fn {a, b} -> a == b end)
        |> length()
      end)

    jaro + prefix_len * 0.1 * (1 - jaro)
  end

  @doc """
  Sends an image to the vision service to extract ISBN candidates, then resolves
  each ISBN via Open Library / Google Books.

  Returns `{:ok, candidates}` where each candidate is a map with `:isbn`,
  `:title`, `:author`, and `:open_library_work_id`.
  Returns `{:error, reason}` if the vision call fails.

  Nothing is committed to the database by this function.
  """
  @spec identify(binary(), {:b64, binary()} | {:url, binary()}) ::
          {:ok, [map()]} | {:error, term()}
  def identify(_user_id, image_input) do
    client = Application.get_env(:core, :vision_client, Stacks.AI.Client)
    payload = build_identify_payload(image_input)

    case client.call_vision("extract_isbn", payload) do
      {:ok, %{"books" => books}} when is_list(books) ->
        {:ok, Enum.flat_map(books, &resolve_candidates/1)}

      {:ok, _other} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_identify_payload({:b64, data}), do: %{image_b64: data}
  defp build_identify_payload({:url, data}), do: %{image_url: data}

  defp resolve_candidates(book_result) do
    book_result
    |> Map.get("potential_isbns", [])
    |> Enum.map(&resolve_isbn_candidate(&1, book_result))
  end

  defp resolve_isbn_candidate(isbn, book_result) do
    metadata =
      case ISBNResolver.resolve(isbn) do
        {:ok, meta} -> meta
        _ -> %{}
      end

    %{
      isbn: isbn,
      title: metadata[:title] || Map.get(book_result, "title"),
      author: metadata[:author] || Map.get(book_result, "author"),
      open_library_work_id: metadata[:open_library_work_id]
    }
  end

  @doc """
  Confirms a book by ISBN, creating the work, primary edition, and placing it
  on a bookshelf for the given user.

  If the ISBN already exists, returns `{:ok, existing_book}` without creating
  a duplicate.

  If a different ISBN resolves to a title+author that fuzzy-matches an existing
  work (Jaro-Winkler score > 0.8), returns
  `{:error, {:merge_required, existing_work_id}}`.

  Otherwise creates the work + primary edition + placement and emits a
  `books.confirmed` event, returning `{:ok, book}`.

  ## Options

    * `:shelf_name` in `attrs` — bookshelf to place on (default `"wishlist"`)
  """
  @spec confirm(binary(), map()) ::
          {:ok, :created, Book.t()}
          | {:ok, :existing, Book.t(), Shelving.Placement.t()}
          | {:ok, :already_placed, Book.t(), Shelving.Placement.t()}
          | {:error, {:merge_required, String.t()}}
          | {:error, term()}
  def confirm(user_id, attrs) do
    isbn = attrs[:isbn] || attrs["isbn"]
    shelf_name = attrs[:shelf_name] || attrs["shelf_name"] || "wishlist"

    with {:ok, isbn} <- require_isbn(isbn),
         nil <- find_existing(isbn),
         {:ok, metadata} <- ISBNResolver.resolve(isbn),
         [] <- find_same_work(metadata[:title] || "Unknown Title", metadata[:author] || "") do
      create_confirmed_book(user_id, isbn, metadata, shelf_name)
    else
      {:error, :missing_isbn} ->
        {:error, :missing_isbn}

      %Book{} = existing ->
        place_or_return_existing(user_id, existing, shelf_name)

      [%{id: existing_work_id} | _] ->
        {:error, {:merge_required, existing_work_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp place_or_return_existing(user_id, book, shelf_name) do
    case Shelving.get_placement_for_book(user_id, book.id) do
      nil -> create_placement_for_existing(user_id, book, shelf_name)
      placement -> {:ok, :already_placed, book, placement}
    end
  end

  defp create_placement_for_existing(user_id, book, shelf_name) do
    case Shelving.place_book(user_id, book.id, shelf_name) do
      {:ok, _} ->
        placement = Shelving.get_placement_for_book(user_id, book.id)
        {:ok, :existing, book, placement}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_isbn(isbn) when is_nil(isbn) or isbn == "", do: {:error, :missing_isbn}
  defp require_isbn(isbn), do: {:ok, isbn}

  defp create_confirmed_book(user_id, isbn, metadata, shelf_name) do
    author_name = metadata[:author]

    with {:ok, author} <- find_or_create_author(author_name) do
      attrs = build_book_attrs(isbn, metadata, author)

      Multi.new()
      |> Multi.insert(:book, %Book{} |> book_changeset(attrs))
      |> Multi.insert(:edition, fn %{book: book} ->
        %BookEdition{}
        |> book_edition_changeset(%{
          "isbn" => isbn,
          "book_id" => book.id,
          "format_label" => metadata[:format_label],
          "cover_image_url" => metadata[:cover_image_url],
          "page_count" => metadata[:page_count],
          "publisher" => metadata[:publisher],
          "publication_year" => metadata[:publication_year],
          "open_library_id" => metadata[:open_library_id],
          "is_primary" => true
        })
      end)
      |> Multi.run(:placement, fn _repo, %{book: book} ->
        Shelving.place_book(user_id, book.id, shelf_name)
      end)
      |> Multi.run(:emit_event, fn _repo, %{book: book, edition: edition} ->
        Events.emit_safe(%{
          event_type: "books.confirmed",
          aggregate_type: "book",
          aggregate_id: book.id,
          payload: %{isbn: edition.isbn, title: book.title, shelf: shelf_name}
        })

        {:ok, book}
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{book: book, edition: edition}} ->
          {:ok, :created, %{book | editions: [edition]}}

        {:error, :book, changeset, _} ->
          {:error, changeset}

        {:error, :edition, changeset, _} ->
          {:error, changeset}

        {:error, _, reason, _} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Merges a new edition (ISBN) into an existing work.

  Creates a non-primary `book_edition` row linked to `work_id`.

  Returns `{:ok, edition}` on success.
  Returns `{:error, :not_found}` when `work_id` does not exist.
  Returns `{:error, changeset}` on validation failure (e.g. duplicate ISBN).
  """
  @spec merge_edition(String.t(), map()) :: {:ok, BookEdition.t()} | {:error, term()}
  def merge_edition(work_id, attrs) do
    isbn = attrs[:isbn] || attrs["isbn"]
    format_label = attrs[:format_label] || attrs["format_label"]

    with {:ok, _meta} <- ISBNResolver.resolve(isbn),
         book when not is_nil(book) <- Repo.get(Book, work_id) do
      insert_edition(book, isbn, format_label, work_id)
    else
      {:error, _} -> {:error, :isbn_not_found}
      nil -> {:error, :not_found}
    end
  end

  defp insert_edition(book, isbn, format_label, work_id) do
    %BookEdition{}
    |> book_edition_changeset(%{
      "isbn" => isbn,
      "book_id" => book.id,
      "format_label" => format_label,
      "is_primary" => false
    })
    |> Repo.insert()
    |> emit_or_classify_edition(isbn, work_id)
  end

  defp emit_or_classify_edition({:ok, edition}, isbn, work_id) do
    Events.emit_safe(%{
      event_type: "books.edition_merged",
      aggregate_type: "book_edition",
      aggregate_id: edition.id,
      payload: %{isbn: isbn, work_id: work_id}
    })

    {:ok, edition}
  end

  defp emit_or_classify_edition({:error, changeset}, _isbn, _work_id) do
    if isbn_taken?(changeset), do: {:error, :duplicate_isbn}, else: {:error, changeset}
  end

  defp isbn_taken?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {field, {_msg, opts}} ->
      field == :isbn and opts[:constraint] == :unique
    end)
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
        |> author_changeset(%{name: name})
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

  # ── Changeset functions (moved from schema modules) ────────────────────

  @doc false
  def book_changeset(book, attrs) do
    book
    |> cast(attrs, @book_required_fields ++ @book_optional_fields)
    |> validate_required(@book_required_fields)
    |> validate_inclusion(:visibility_tier, ["public", "age_gated"])
  end

  @doc false
  def author_changeset(author, attrs) do
    author
    |> cast(attrs, @author_cast_fields)
    |> validate_required([:name])
  end

  @doc false
  def book_edition_changeset(edition, attrs) do
    edition
    |> cast(attrs, @edition_required_fields ++ @edition_optional_fields)
    |> validate_required(@edition_required_fields)
    |> validate_format(:isbn, ~r/^\d{10}(\d{3})?$/, message: "must be a valid ISBN-10 or ISBN-13")
    |> validate_isbn_checksum()
    |> unique_constraint(:isbn)
  end

  @doc false
  def uploaded_image_changeset(image, attrs) do
    image
    |> cast(attrs, @image_cast_fields)
    |> validate_required([:status, :uploaded_at, :expires_at])
    |> validate_inclusion(:status, @valid_image_statuses)
  end

  defp validate_isbn_checksum(changeset) do
    validate_change(changeset, :isbn, fn :isbn, isbn ->
      if valid_isbn_checksum?(isbn) do
        []
      else
        [isbn: "has an invalid checksum"]
      end
    end)
  end

  defp valid_isbn_checksum?(isbn) do
    if isbn =~ ~r/^\d{10}$|^\d{13}$/ do
      digits = Enum.map(String.graphemes(isbn), &String.to_integer/1)

      case length(digits) do
        13 -> isbn13_valid?(digits)
        10 -> isbn10_valid?(digits)
        _ -> false
      end
    else
      true
    end
  end

  defp isbn13_valid?(digits) do
    sum =
      digits
      |> Enum.with_index()
      |> Enum.reduce(0, fn {d, i}, acc ->
        weight = if rem(i, 2) == 0, do: 1, else: 3
        acc + d * weight
      end)

    rem(sum, 10) == 0
  end

  defp isbn10_valid?(digits) do
    sum =
      digits
      |> Enum.take(9)
      |> Enum.with_index()
      |> Enum.reduce(0, fn {d, i}, acc -> acc + d * (10 - i) end)

    check = rem(11 - rem(sum, 11), 11)
    check != 10 and check == Enum.at(digits, 9)
  end
end
