defmodule Stacks.Books do
  @moduledoc """
      Books context — book creation, discovery, and ISBN resolution.

      A **book** (work) is the logical entity; a **book_edition** is one ISBN/format
      of it. The ISBN hard gate is enforced here: every edition needs a verified
      ISBN. Pure ISBN arithmetic lives in `Stacks.Books.ISBN`; upload-photo
      lifecycle lives in `Stacks.Uploads` — neither is part of this contract.
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
  alias Stacks.Books.{Author, Book, BookEdition}
  alias Stacks.Books.BookDetailCache
  alias Stacks.Books.ISBN
  alias Stacks.Books.ISBNResolver
  alias Stacks.Events
  alias Stacks.Shelving

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

  @edition_required_fields [:isbn, :book_id, :verification_source]
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

  @verification_sources ~w(open_library google_books barcode_unverified)

  @doc """
      Returns a book edition by ID, or nil if not found.
  """
  @spec get_edition(binary()) :: BookEdition.t() | nil
  def get_edition(id), do: Repo.get(BookEdition, id)

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
      Returns the primary edition, falling back to the earliest-created one.

      Deterministic on purpose (`is_primary`, then oldest `created_at`, then
      smallest `id`): callers like the page-count ceiling must resolve the same
      edition every time, with or without preloads.
  """
  @spec primary_edition(Book.t()) :: BookEdition.t() | nil
  def primary_edition(%Book{editions: editions}) when is_list(editions) do
    editions
    |> Enum.sort_by(&edition_sort_key/1)
    |> List.first()
  end

  def primary_edition(%Book{id: book_id}) do
    BookEdition
    |> where([e], e.book_id == ^book_id)
    |> order_by([e], desc: e.is_primary, asc: e.created_at, asc: e.id)
    |> limit(1)
    |> Repo.one()
  end

  defp edition_sort_key(edition) do
    {edition.is_primary != true, edition_time_key(edition.created_at), edition.id}
  end

  defp edition_time_key(%DateTime{} = created_at), do: DateTime.to_unix(created_at, :microsecond)
  defp edition_time_key(nil), do: 0

  @doc """
      Finds an existing book (work) by ISBN — looks up the edition, returns the parent work.
  """
  @spec find_existing(String.t()) :: Book.t() | nil
  def find_existing(isbn) do
    case find_existing_edition(isbn) do
      nil -> nil
      edition -> edition.book
    end
  end

  @doc """
      Like `find_existing/1`, but returns the matched EDITION (with its parent work
      preloaded), not just the work. The scan resolves by a specific ISBN, so the
      edition it matched is the printing the reader owns — the caller keeps it so the
      placement can record it, instead of discarding it and defaulting to the
      work's primary edition.
  """
  @spec find_existing_edition(String.t()) :: BookEdition.t() | nil
  def find_existing_edition(isbn) do
    isbn13 = ISBN.to_isbn13(isbn)

    BookEdition
    |> where([e], e.isbn == ^isbn13)
    |> preload(book: [:author, :editions])
    |> Repo.one()
  end

  @doc """
      Creates a book (work) with its first edition from attributes.
      Requires `:isbn` and `:title`.

      Attributes are string-keyed. `"author"` (a name) is resolved to an
      `op.authors` row; callers holding an id may pass `"author_id"` instead.
      `"verification_source"` may be stated explicitly by a caller that knows the
      provenance; otherwise it is derived from the identifiers in `attrs`.
  """
  @spec create(map()) :: {:ok, Book.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs), do: create_work(attrs, event: &book_created_event/2)

  defp create_work(attrs, opts) do
    with {:ok, author} <- find_or_create_author(attrs["author"]) do
      Multi.new()
      |> Multi.insert(:book, book_changeset(%Book{}, book_attrs(attrs, author)))
      |> Multi.insert(:edition, fn %{book: book} ->
        book_edition_changeset(%BookEdition{}, edition_attrs(attrs, book))
      end)
      |> maybe_place(opts[:place])
      |> Multi.run(:emit_event, fn _repo, %{book: book, edition: edition} ->
        Events.emit_safe(opts[:event].(book, edition))
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
  end

  defp book_attrs(attrs, nil), do: attrs
  defp book_attrs(attrs, author), do: Map.put(attrs, "author_id", author.id)

  defp edition_attrs(attrs, book) do
    %{
      "isbn" => attrs["isbn"],
      "book_id" => book.id,
      "format_label" => attrs["format_label"],
      "cover_image_url" => attrs["cover_image_url"],
      "page_count" => attrs["page_count"],
      "publisher" => attrs["publisher"],
      "publication_year" => attrs["publication_year"],
      "open_library_id" => attrs["open_library_id"],
      "google_books_id" => attrs["google_books_id"],
      "is_primary" => true,
      "verification_source" => attrs["verification_source"] || verification_source_from(attrs)
    }
  end

  defp maybe_place(multi, nil), do: multi

  defp maybe_place(multi, {user_id, shelf_name}) do
    Multi.run(multi, :placement, fn _repo, %{book: book} ->
      Shelving.place_book(user_id, book.id, shelf_name)
    end)
  end

  defp book_created_event(book, edition) do
    %{
      event_type: "book.created",
      aggregate_type: "book",
      aggregate_id: book.id,
      payload: %{
        isbn: edition.isbn,
        title: book.title,
        visibility_tier: book.visibility_tier
      }
    }
  end

  defp books_confirmed_event(book, edition, shelf_name) do
    %{
      event_type: "books.confirmed",
      aggregate_type: "book",
      aggregate_id: book.id,
      payload: %{isbn: edition.isbn, title: book.title, shelf: shelf_name}
    }
  end

  @doc """
      Sets a book's `visibility_tier` to `"public"` or `"age_gated"` — a PERSON
      marks a book, code never guesses.

      Options: `:source` (`:user` default | `:owner`; telemetry-only), and
      `:raise_only` (`true` default) — the user path may only RAISE the gate;
      lowering returns `{:error,:forbidden}` and is owner-only.
  """
  @spec set_visibility_tier(Book.t() | binary(), String.t(), keyword()) ::
          {:ok, Book.t()} | {:error, :not_found | :forbidden | Ecto.Changeset.t()}
  def set_visibility_tier(book_or_id, tier, opts \\ [])

  def set_visibility_tier(book_id, tier, opts) when is_binary(book_id) do
    case Repo.get(Book, book_id) do
      nil -> {:error, :not_found}
      book -> set_visibility_tier(book, tier, opts)
    end
  end

  def set_visibility_tier(%Book{} = book, tier, opts) when tier in ["public", "age_gated"] do
    source = Keyword.get(opts, :source, :user)
    raise_only = Keyword.get(opts, :raise_only, true)

    cond do
      book.visibility_tier == tier ->
        {:ok, book}

      raise_only and not raising_gate?(book.visibility_tier, tier) ->
        {:error, :forbidden}

      true ->
        book
        |> book_changeset(%{"visibility_tier" => tier})
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            emit_tiering(updated.visibility_tier, source)
            evict_then_announce(updated, source)
            {:ok, updated}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  # The eviction is SYNCHRONOUS and the event is only the audit trail —
  # deliberately in that order, and deliberately not the event alone.
  #
  # `GET /api/books/:id` enforces the age gate against whatever
  # `cached_or_fetch/1` returned, so until the `BookDetailCache` entry is gone the
  # raised gate is not applied to anybody: a probe against a live database read
  # `tier="public"`, raised the tier, and read `tier="public"` again — for the
  # full 5-minute TTL. Routing this through the event bus alone (the wire
  # `books.edition_merged` uses) would replace a 5-minute window with a shorter
  # one, and a **content-safety control must not have a deferral window whose
  # width is queue latency**. So the cache is evicted in this process, before the
  # caller is told the write succeeded. The event still goes out: `event_log` is
  # where "this book was marked adults-only, by this kind of actor, at this time"
  # becomes durable, and its subscription covers any future emitter of this type
  # that is not this function.
  #
  # Payload carries the WORK id — what the cache is keyed by — rather than
  # leaving the subscriber to read `aggregate_id`, because "the aggregate happens
  # to be the cache key" is the assumption that made `book.cover_confirmed`
  # silently evict nothing. `visibility_tier` is the same closed
  # two-value enum `book.created` already carries. Nothing identifies the actor
  # beyond `metadata.actor`'s `"user" | "owner"`: no id, no free text.
  defp evict_then_announce(%Book{} = book, source) do
    BookDetailCache.invalidate(book.id)

    Events.emit_safe(%{
      event_type: "book.visibility_tier_changed",
      aggregate_type: "book",
      aggregate_id: book.id,
      payload: %{book_id: book.id, visibility_tier: book.visibility_tier},
      metadata: %{actor: to_string(source)}
    })

    :ok
  end

  defp raising_gate?("public", "age_gated"), do: true
  defp raising_gate?(_from, _to), do: false

  defp emit_tiering(tier, source) when source in [:user, :owner] do
    :telemetry.execute(
      [:stacks, :moderation, :tiering],
      %{count: 1},
      %{tier: tier_atom(tier), source: source}
    )
  end

  defp tier_atom("age_gated"), do: :age_gated
  defp tier_atom("public"), do: :public

  @doc """
      Resolves book metadata from an ISBN via Open Library / Google Books,
      then creates the book (work) and edition records.

      A resolver failure is reported as what it was — `:isbn_not_found` only when
      the upstreams answered and did not know the ISBN, `:resolver_unavailable`
      when they did not answer at all. See `resolver_failure/1`.
  """
  @spec create_from_isbn(String.t()) ::
          {:ok, Book.t()}
          | {:error, :isbn_not_found | :resolver_unavailable | Ecto.Changeset.t()}
  def create_from_isbn(isbn) do
    with :ok <- validate_isbn_format(isbn),
         {:ok, metadata} <- resolve_for_write(isbn) do
      isbn |> attrs_from_resolved(metadata) |> create()
    end
  end

  defp resolve_for_write(isbn) do
    case ISBNResolver.resolve(isbn) do
      {:ok, metadata} -> {:ok, metadata}
      {:error, reason} -> {:error, resolver_failure(reason)}
    end
  end

  @spec resolver_failure(term()) :: :isbn_not_found | :resolver_unavailable
  defp resolver_failure(reason) do
    if ISBNResolver.resolver_error?(reason) do
      case ISBNResolver.determination(reason) do
        :not_found -> :isbn_not_found
        :unavailable -> :resolver_unavailable
      end
    else
      Logger.warning(
        "Books: ISBN resolver returned #{inspect(reason)}, which is outside " <>
          "ISBNResolver.error_reason/0 — treating as unavailable (a reason we cannot " <>
          "name says nothing about the ISBN)"
      )

      :resolver_unavailable
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
  @spec resolve_isbn(String.t()) ::
          {:ok, map()} | {:error, ISBNResolver.error_reason()}
  def resolve_isbn(isbn) do
    ISBNResolver.resolve(isbn)
  end

  @doc """
      Paginated public catalogue of works — no ownership data.

      Options: `:search` (title tsv), `:subject`, `:sort` (`"title"` default,
      `"author"`, `"recent"`), `:page` (1-based), `:per_page` (24, max 100).
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

  @doc """
      Lists books for the owner moderation surface. Unlike `list_catalogue/1` it
      NEVER hides age-gated books — the owner must see every tier; the admin
      pipeline gates the route. Options: `:search`, `:tier`, `:page`,
      `:per_page` (50, max 100). Returns `{books, total_count}`.
  """
  @spec list_for_moderation(keyword()) :: {[Book.t()], non_neg_integer()}
  def list_for_moderation(opts \\ []) do
    search = Keyword.get(opts, :search)
    tier = Keyword.get(opts, :tier)
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = min(max(Keyword.get(opts, :per_page, 50), 1), 100)
    offset = (page - 1) * per_page

    filtered =
      Book
      |> preload([:author, :editions])
      |> maybe_search(search)
      |> maybe_filter_tier(tier)

    total = Repo.aggregate(filtered, :count)

    books =
      filtered
      |> order_by([b], asc: b.title)
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()

    {books, total}
  end

  defp maybe_filter_tier(query, nil), do: query
  defp maybe_filter_tier(query, ""), do: query

  defp maybe_filter_tier(query, tier) when tier in ["public", "age_gated"] do
    where(query, [b], b.visibility_tier == ^tier)
  end

  defp maybe_filter_tier(query, _tier), do: query

  defp maybe_search(query, nil), do: query
  defp maybe_search(query, ""), do: query

  defp maybe_search(query, search) do
    where(
      query,
      [b],
      fragment("title_tsv @@ plainto_tsquery('english', ?)", ^search)
    )
  end

  defp maybe_filter_subject(query, nil), do: query
  defp maybe_filter_subject(query, ""), do: query

  defp maybe_filter_subject(query, subject) do
    where(query, [b], ^subject in b.subjects)
  end

  defp maybe_exclude_age_gated(query, {:platform_user, _id, true}), do: query

  defp maybe_exclude_age_gated(query, _viewer) do
    if Stacks.FeatureFlags.age_gating_enabled?() do
      where(query, [b], b.visibility_tier != "age_gated")
    else
      query
    end
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
      Full-text search over the stored tsvector columns; up to `:limit` results
      (default 20). `:scope` — `:title` (default) matches titles only; `:deep`
      also matches descriptions, ranking title matches first.
  """
  @spec search_books(String.t(), keyword()) :: [Book.t()]
  def search_books(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    scope = Keyword.get(opts, :scope, :title)

    Book
    |> search_scope_where(scope, query)
    |> search_scope_order(scope, query)
    |> preload([:author, :editions])
    |> limit(^limit)
    |> Repo.all()
  end

  defp search_scope_where(query_ast, :deep, query) do
    where(
      query_ast,
      [b],
      fragment("title_tsv @@ plainto_tsquery('english', ?)", ^query) or
        fragment("description_tsv @@ plainto_tsquery('english', ?)", ^query)
    )
  end

  defp search_scope_where(query_ast, _title, query) do
    where(query_ast, [b], fragment("title_tsv @@ plainto_tsquery('english', ?)", ^query))
  end

  defp search_scope_order(query_ast, :deep, query) do
    order_by(
      query_ast,
      [b],
      desc: fragment("(title_tsv @@ plainto_tsquery('english', ?))", ^query),
      asc: b.title
    )
  end

  defp search_scope_order(query_ast, _title, _query), do: query_ast

  @doc """
      Builds `ts_headline` description snippets for a deep search: returns
      `%{book_id => snippet}` with matches wrapped in `<mark>…</mark>`. Books whose
      description did not match (title-only hits) are ABSENT from the map.
  """
  @spec description_snippets([binary()], String.t()) :: %{binary() => String.t()}
  def description_snippets([], _query), do: %{}

  def description_snippets(book_ids, query) when is_list(book_ids) do
    Book
    |> where([b], b.id in ^book_ids)
    |> where([b], fragment("description_tsv @@ plainto_tsquery('english', ?)", ^query))
    |> select(
      [b],
      {b.id,
       fragment(
         "ts_headline('english', coalesce(?, ''), plainto_tsquery('english', ?), 'StartSel=<mark>, StopSel=</mark>')",
         b.description,
         ^query
       )}
    )
    |> Repo.all()
    |> Map.new()
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
              payload: %{book_id: updated.book_id, cover_image_url: final_url},
              metadata: %{actor: "vision_sidecar"}
            })

            {:ok, updated}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  defp maybe_store_cover_in_r2(isbn, cover_url) when is_binary(isbn) do
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
    books_http_client().get_binary(url)
  end

  defp books_http_client do
    Application.get_env(:core, :isbn_http_client, Stacks.Books.HttpClient)
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
      Confirms a book by ISBN: creates work + primary edition + placement and
      emits `books.confirmed`. An existing ISBN returns `{:ok, existing_book}`;
      a title+author fuzzy match to another work (Jaro-Winkler > 0.8) returns
      `{:error, {:merge_required, work_id}}`. `attrs["shelf_name"]` picks the
      bookshelf (default `"wishlist"`).
  """
  @spec confirm(binary(), map()) ::
          {:ok, :created, Book.t()}
          | {:ok, :existing, Book.t(), Shelving.Placement.t(), [Shelving.Placement.t()]}
          | {:ok, :already_placed, Book.t(), Shelving.Placement.t(), [Shelving.Placement.t()]}
          | {:error, {:merge_required, String.t()}}
          | {:error, term()}
  def confirm(user_id, attrs) do
    isbn = attrs[:isbn] || attrs["isbn"]
    shelf_name = attrs[:shelf_name] || attrs["shelf_name"] || "wishlist"

    with {:ok, isbn} <- require_isbn(isbn),
         nil <- find_existing_edition(isbn),
         {:ok, metadata} <- resolve_for_write(isbn),
         [] <- find_same_work(metadata[:title] || "Unknown Title", metadata[:author] || "") do
      create_confirmed_book(user_id, isbn, metadata, shelf_name)
    else
      {:error, :missing_isbn} ->
        {:error, :missing_isbn}

      %BookEdition{} = edition ->
        place_or_return_existing(user_id, edition.book, shelf_name, edition.id)

      [%{id: existing_work_id} | _] ->
        {:error, {:merge_required, existing_work_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp place_or_return_existing(user_id, book, shelf_name, book_edition_id) do
    placements = Shelving.get_placements_for_book(user_id, book.id)

    case Enum.find(placements, &(&1.bookshelf.name == shelf_name)) do
      nil -> create_placement_for_existing(user_id, book, shelf_name, placements, book_edition_id)
      placement -> {:ok, :already_placed, book, placement, placements}
    end
  end

  defp create_placement_for_existing(user_id, book, shelf_name, existing, book_edition_id) do
    case Shelving.place_book(user_id, book.id, shelf_name, book_edition_id) do
      {:ok, placement} ->
        placement = Repo.preload(placement, :bookshelf)
        {:ok, :existing, book, placement, existing ++ [placement]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_isbn(isbn) when is_nil(isbn) or isbn == "", do: {:error, :missing_isbn}
  defp require_isbn(isbn), do: {:ok, isbn}

  defp create_confirmed_book(user_id, isbn, metadata, shelf_name) do
    attrs = attrs_from_resolved(isbn, metadata)

    case create_work(attrs,
           place: {user_id, shelf_name},
           event: &books_confirmed_event(&1, &2, shelf_name)
         ) do
      {:ok, book} -> {:ok, :created, book}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
      Merges a new edition (ISBN) into an existing work as a non-primary row.
      Errors: `:not_found` (work), `:isbn_not_found` (upstreams rejected it),
      `:resolver_unavailable` (upstreams unreachable), or a changeset.
  """
  @spec merge_edition(String.t(), map()) :: {:ok, BookEdition.t()} | {:error, term()}
  def merge_edition(work_id, attrs) do
    isbn = attrs[:isbn] || attrs["isbn"]
    format_label = attrs[:format_label] || attrs["format_label"]

    with {:ok, meta} <- resolve_for_write(isbn),
         book when not is_nil(book) <- Repo.get(Book, work_id) do
      insert_edition(book, isbn, format_label, work_id, meta)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  defp insert_edition(book, isbn, format_label, work_id, meta) do
    %BookEdition{}
    |> book_edition_changeset(%{
      "isbn" => isbn,
      "book_id" => book.id,
      "format_label" => format_label,
      "cover_image_url" => meta[:cover_image_url],
      "page_count" => meta[:page_count],
      "publisher" => meta[:publisher],
      "publication_year" => meta[:publication_year],
      "open_library_id" => meta[:open_library_id],
      "google_books_id" => meta[:google_books_id],
      "is_primary" => false,
      "verification_source" => verification_source_from(meta)
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

  @doc """
      Finds an author by exact name, inserting if absent. `{:ok, nil}` for
      nil/empty input (enrichment sources may carry no author). Public so
      `EnrichBookJob` can link resolver author strings to `op.authors` rows.
  """
  @spec find_or_create_author(String.t() | nil) ::
          {:ok, Author.t() | nil} | {:error, Ecto.Changeset.t()}
  def find_or_create_author(nil), do: {:ok, nil}
  def find_or_create_author(""), do: {:ok, nil}

  def find_or_create_author(name) when is_binary(name) do
    case String.trim(name) do
      "" ->
        {:ok, nil}

      trimmed ->
        case Repo.get_by(Author, name: trimmed) do
          nil ->
            %Author{}
            |> author_changeset(%{name: trimmed})
            |> Repo.insert()

          author ->
            {:ok, author}
        end
    end
  end

  defp attrs_from_resolved(isbn, metadata) do
    %{
      "isbn" => isbn,
      "title" => metadata[:title] || "Unknown Title",
      "author" => metadata[:author],
      "description" => metadata[:description],
      "subjects" => metadata[:subjects] || [],
      "format_label" => metadata[:format_label],
      "cover_image_url" => metadata[:cover_image_url],
      "publisher" => metadata[:publisher],
      "publication_year" => metadata[:publication_year],
      "page_count" => metadata[:page_count],
      "open_library_id" => metadata[:open_library_id],
      "google_books_id" => metadata[:google_books_id]
    }
  end

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

  @doc """
      The closed set of values `book_editions.verification_source` may hold.

      Public so callers and tests name the same list the CHECK constraint does
      rather than re-spelling the strings.
  """
  @spec verification_sources() :: [String.t()]
  def verification_sources, do: @verification_sources

  @doc """
      Derives an edition's ISBN provenance from resolver metadata: the
      cross-reference id present names the confirming catalogue
      (`open_library`/`google_books`); neither present means nothing external
      confirmed it — `"barcode_unverified"`.
  """
  @spec verification_source_from(map()) :: String.t()
  def verification_source_from(metadata) when is_map(metadata) do
    cond do
      present?(metadata[:open_library_id] || metadata["open_library_id"]) -> "open_library"
      present?(metadata[:google_books_id] || metadata["google_books_id"]) -> "google_books"
      true -> "barcode_unverified"
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  @doc """
      Vets one raw `op.book_editions` row through the production changeset before
      `insert_all/3` (which bypasses changesets entirely), returning it with the
      normalised `isbn`. Raises `ArgumentError` for a row production could not
      write — seed fixtures must not be able to ship invalid ISBNs.
  """
  @spec vet_edition_row!(map()) :: map()
  def vet_edition_row!(row) when is_map(row) do
    changeset = book_edition_changeset(%BookEdition{}, castable_edition_row(row))

    if changeset.valid? do
      %{row | isbn: get_field(changeset, :isbn)}
    else
      raise ArgumentError, """
      seed edition row is not one a production write path could produce:
        isbn:    #{inspect(row[:isbn])}
        errors:  #{inspect(changeset_error_messages(changeset))}
      Fix the row in priv/repo/seeds.exs — do not relax this check.
      """
    end
  end

  @edition_row_cast_keys [:isbn, :book_id, :verification_source] ++
                           [
                             :format_label,
                             :cover_image_url,
                             :page_count,
                             :publisher,
                             :publication_year,
                             :open_library_id,
                             :google_books_id,
                             :is_primary
                           ]

  defp castable_edition_row(row) do
    row
    |> Map.take(@edition_row_cast_keys)
    |> Map.replace_lazy(:book_id, &load_uuid/1)
  end

  defp load_uuid(<<_::128>> = raw), do: Ecto.UUID.load!(raw)
  defp load_uuid(other), do: other

  defp changeset_error_messages(changeset) do
    traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  @doc false
  def book_edition_changeset(edition, attrs) do
    edition
    |> cast(attrs, @edition_required_fields ++ @edition_optional_fields)
    |> validate_required(@edition_required_fields)
    |> validate_inclusion(:verification_source, @verification_sources)
    |> validate_format(:isbn, ~r/^\d{10}(\d{3})?$/, message: "must be a valid ISBN-10 or ISBN-13")
    |> validate_isbn_checksum()
    |> normalize_edition_isbn()
    |> unique_constraint(:isbn)
    |> check_constraint(:isbn,
      name: :book_editions_isbn_ean13_checksum,
      message: "must be a valid ISBN-13 with a correct check digit"
    )
    |> check_constraint(:verification_source,
      name: :book_editions_verification_source_check,
      message: "is invalid"
    )
  end

  defp normalize_edition_isbn(%{valid?: false} = changeset), do: changeset

  defp normalize_edition_isbn(changeset) do
    case get_change(changeset, :isbn) do
      nil -> changeset
      isbn -> put_change(changeset, :isbn, ISBN.to_isbn13(isbn))
    end
  end

  defp validate_isbn_checksum(changeset) do
    validate_change(changeset, :isbn, fn :isbn, isbn ->
      if ISBN.valid_isbn_checksum?(isbn) do
        []
      else
        [isbn: "has an invalid checksum"]
      end
    end)
  end
end
