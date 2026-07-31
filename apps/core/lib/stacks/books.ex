defmodule Stacks.Books do
  @moduledoc """
  Books context — book creation, discovery, and ISBN resolution.

  In the works/editions model:
  - A **book** (work) is the logical entity: "Circe" by Madeline Miller
  - A **book_edition** is a specific ISBN/format: "Circe, Bloomsbury paperback, 9780316556347"

  The ISBN hard gate is enforced here: every edition must have a verified ISBN.

  Two neighbours were carved out of this module in #345, and what they are NOT
  is part of this context's contract:

    * `Stacks.Books.ISBN` — check digits and the ISBN-10 → ISBN-13 canonical
      form. Pure string arithmetic; no repo.
    * `Stacks.Uploads` — the `op.uploaded_images` row lifecycle. An image
      becomes a book by way of `Stacks.Workers.IdentifyBookJob`, not by way of
      this module.
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
  alias Stacks.Books.ISBN
  alias Stacks.Books.ISBNResolver
  alias Stacks.Events
  alias Stacks.Shelving

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

  # The closed set of ISBN-verification provenances (#335 D1). Mirrored by the
  # `book_editions_verification_source_check` CHECK constraint and the
  # `accepted_values` dbt test on stg_book_editions.
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
  Returns the primary edition for a book, or the earliest-created edition as a
  fallback.

  The pick is deterministic: `is_primary` first, then the oldest `created_at`,
  then the smallest `id`. The page-count ceiling (`Shelving`) leans on this
  edition, so a book with no (or multiple) `is_primary` flag must resolve to the
  same edition every time — both here (preloaded editions) and in the query
  clause below.
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

  # Sort key mirroring the query clause's `desc: is_primary, asc: created_at,
  # asc: id`. `is_primary != true` maps the primary edition to `false` (0) so it
  # sorts ahead of the non-primary ones; `created_at` is compared chronologically
  # via Unix microseconds (Erlang term order over %DateTime{} is NOT
  # chronological), with `id` as the final tiebreak.
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
    isbn13 = ISBN.to_isbn13(isbn)

    BookEdition
    |> where([e], e.isbn == ^isbn13)
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

  Attributes are string-keyed. `"author"` (a name) is resolved to an
  `op.authors` row; callers holding an id may pass `"author_id"` instead.
  `"verification_source"` may be stated explicitly by a caller that knows the
  provenance; otherwise it is derived from the identifiers in `attrs`.
  """
  @spec create(map()) :: {:ok, Book.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs), do: create_work(attrs, event: &book_created_event/2)

  # ── The one create transaction (#341) ────────────────────────────────────
  #
  # Every path that mints a work and its first edition arrives here. There used
  # to be two — `create/1` and a private `create_confirmed_book/4` — and they had
  # drifted: the confirmed one silently dropped `google_books_id`, so an edition
  # the platform had just paid a Google Books round-trip for lost both the
  # cross-reference AND (since `verification_source_from/1` reads provenance off
  # exactly those identifiers) its claim to have been verified at all.
  #
  # The two callers differ only in what they ADD to the create — a bookshelf
  # placement, and which event they emit — so those are options, not a reason for
  # a second implementation.
  #
  # `opts`:
  #   * `:event` — `(book, edition -> map)` building the event to emit.
  #   * `:place` — `{user_id, shelf_name}` to place the new book inside the same
  #     transaction, or absent for a catalogue-only create.
  defp create_work(attrs, opts) do
    # Resolved before the Multi so an author-insert failure is reported as
    # itself rather than as an aborted transaction. `create/1` used to swallow
    # this error and mint an author-less book; the confirmed path already
    # propagated it, and propagating is the answer that cannot lose data.
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

  # The edition columns the create transaction writes. This list IS the contract
  # the two former implementations disagreed about — keep it exhaustive.
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
      # Callers that KNOW the provenance say so (Moderation's barcode fast
      # path); everyone else has it read off the identifiers the resolver
      # returned.
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
  Sets a book's `visibility_tier` to `"public"` or `"age_gated"`.

  This replaced the removed automatic subject→BISAC age-gate classifier: a
  book is age-gated because a PERSON marked it, not because code guessed.

  `opts`:
    * `:source` — `:user` (default) | `:owner`. Only recorded on the
      `[:stacks, :moderation, :tiering]` telemetry, never persisted.
    * `:raise_only` — `true` (default). The safety rule for the USER path:
      permit only `public → age_gated` (raising the gate). Attempting to
      LOWER (`age_gated → public`) returns `{:error, :forbidden}` — only the
      owner may un-gate, and the owner path passes `raise_only: false`.

  Emits the `[:stacks, :moderation, :tiering]` counter (measurement
  `%{count: 1}`, metadata `%{tier: :public | :age_gated, source: :user |
  :owner}`) only on a successful CHANGE — a no-op (tier already matches) is
  silent. Metadata is low-cardinality whitelisted atoms only (no ids/PII).

  Accepts a `%Book{}` or a book id. Returns `{:ok, book}` or
  `{:error, :not_found | :forbidden | Ecto.Changeset.t()}`.
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
        # No-op: the tier already matches. Succeed without emitting telemetry.
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
            {:ok, updated}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  # Raising the gate is only public → age_gated. Everything else (already
  # age_gated, or a lower) is not a raise.
  defp raising_gate?("public", "age_gated"), do: true
  defp raising_gate?(_from, _to), do: false

  # Repointed age-gate tiering counter (formerly emitted by the removed
  # pipeline classifier). `tier` is a whitelisted atom (:public /
  # :age_gated) and `source` is :user / :owner — no BISAC code, ISBN,
  # title, or id in metadata (GDPR: telemetry is a warehouse-adjacent sink).
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

  # The one place a resolver result becomes this context's vocabulary.
  #
  # Every write path that needs metadata (`create_from_isbn/1`, `confirm/2`,
  # `merge_edition/2`) goes through here, so none of them can reintroduce the
  # `{:error, _}` collapse that made a Google Books outage indistinguishable
  # from an ISBN nobody has ever heard of.
  defp resolve_for_write(isbn) do
    case ISBNResolver.resolve(isbn) do
      {:ok, metadata} -> {:ok, metadata}
      {:error, reason} -> {:error, resolver_failure(reason)}
    end
  end

  # `:isbn_not_found` is a claim about the ISBN and is only made when the
  # upstreams actually made it. `:resolver_unavailable` says the lookup did not
  # happen — nothing was learned about this book, so nothing about this book is
  # recorded. Callers map the two to different HTTP answers (422 vs 503).
  #
  # The `resolver_error?/1` guard is not ceremony. `determination/1` is written
  # without a catch-all so that a NEW `error_reason/0` cannot ship unclassified,
  # and that property is worth keeping — but it means an atom from outside the
  # contract raises, and this runs inside a Phoenix action, where a raise is a
  # 500. An HTTP client that breaks its behaviour (or a test double that invents
  # a reason, which is how this was found: `:service_unavailable`, a value
  # `Stacks.Books.HttpClient` cannot produce) then costs the reader a crash.
  #
  # It degrades to `:resolver_unavailable`, never to `:isbn_not_found`, because
  # that is the whole rule: a failure we cannot even name is certainly not
  # evidence about the book. Same shape as
  # `Stacks.Workers.IdentifyBookJob.rejection_token/1`.
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

  @doc """
  Lists books for the owner moderation surface (#118 owner age-gate override).

  Unlike `list_catalogue/1`, this NEVER hides age-gated books — the platform
  owner must see and act on every book regardless of tier. There is no viewer
  filter here; the route is gated by the MFA-verified admin pipeline.

  `opts`:
    * `:search` — free-text search against `title_tsv` (optional)
    * `:tier` — `"public"` | `"age_gated"` filter (optional)
    * `:page` — 1-based page number (default 1)
    * `:per_page` — items per page (default 50, max 100)

  Returns `{books, total_count}`, each book preloaded with `:author` and
  `:editions` so the caller can surface title/author/cover/isbn.
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
    # Raw query straight to `plainto_tsquery` via the bound param — same rationale
    # as `search_books/2` (#291): injection-safety comes from Ecto binding +
    # plainto_tsquery treating input as plain text, NOT from stripping characters.
    # This path uses `plainto_tsquery` (not `ilike`), so there are no `%`/`_`
    # wildcard semantics to escape. A prior `String.replace(~r/[^\w\s]/)` sanitiser
    # was lossy — "O'Brien" → "OBrien", "spider-man" → "spiderman" (#296).
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

  # #229: age-gated books are hidden from listing surfaces for any viewer who is
  # not age-verified — anonymous OR authenticated-but-unverified. This must stay a
  # SQL-level predicate so `total`/pagination (see list_catalogue/1) counts stay
  # correct; an in-memory post-filter would break paging.
  #
  # Fail closed: ONLY a verified platform user (`{:platform_user, _id, true}`) is
  # left unfiltered. Every other viewer shape — anonymous, unverified, or any
  # unexpected/legacy tuple — has age-gated books excluded by default, so a future
  # caller passing a stale 2-tuple can never silently leak age-gated content.
  defp maybe_exclude_age_gated(query, {:platform_user, _id, true}), do: query

  defp maybe_exclude_age_gated(query, _viewer) do
    # Shipped dark (ADR-020): when age-gating is disabled the listing filter is a
    # no-op for EVERY viewer — age-gated books are shown like public ones. Only
    # `list_for_moderation`/`maybe_filter_tier` (owner-only) stays tier-aware.
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
  Full-text search on books using the stored tsvector columns.

  Returns up to `limit` results (default 20).

  ## Options

    * `:limit` — max results (default 20)
    * `:scope` — `:title` (default) matches `title_tsv` only; `:deep` (#284)
      ALSO matches `description_tsv`, so a book whose description mentions the
      query surfaces even when its title does not. Under `:deep`, title matches
      are ordered ahead of description-only matches (a boolean title-match key,
      DESC, then title ASC) so the most-relevant hits stay first; the default
      title scope is unchanged.

  In both scopes the raw query is passed straight to `plainto_tsquery` via the
  bound param: injection-safety comes from Ecto param binding + `plainto_tsquery`
  treating its input as plain text (proven by the #115 edge-case suite), NOT from
  stripping characters. A prior `String.replace(~r/[^\w\s]/)` sanitiser was
  lossy — "O'Brien" → "OBrien", "spider-man" → "spiderman" — which changed the
  lexemes and dropped legitimate matches (#291).
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

  # Under deep scope, rank title matches ahead of description-only matches: the
  # boolean `title_tsv @@ ...` sorts `true` before `false` under DESC, then title
  # breaks ties alphabetically. Title scope keeps its implicit (unordered) shape.
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
  Builds `ts_headline` description snippets for a deep search (#284).

  Given a list of `book_ids` and the raw `query`, returns a map
  `%{book_id => snippet}` for every book in the list whose `description_tsv`
  matches — the "why this matched" excerpt behind US-1.5.2. Books whose
  description does NOT match (title-only hits) are absent from the map, so the
  caller leaves their snippet empty. The excerpt wraps matched lexemes in
  `<mark>…</mark>`. Same `plainto_tsquery` injection-safety rationale as
  `search_books/2`.
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
          | {:ok, :existing, Book.t(), Shelving.Placement.t(), [Shelving.Placement.t()]}
          | {:ok, :already_placed, Book.t(), Shelving.Placement.t(), [Shelving.Placement.t()]}
          | {:error, {:merge_required, String.t()}}
          | {:error, term()}
  def confirm(user_id, attrs) do
    isbn = attrs[:isbn] || attrs["isbn"]
    shelf_name = attrs[:shelf_name] || attrs["shelf_name"] || "wishlist"

    with {:ok, isbn} <- require_isbn(isbn),
         nil <- find_existing(isbn),
         {:ok, metadata} <- resolve_for_write(isbn),
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

  # Decision (#333): branch on "is it already on the bookshelf they asked for?",
  # not on "does a placement exist anywhere?".
  #
  # The old `nil | placement` branch treated ANY existing placement as
  # already-placed, so asking to add a wish-listed book to your Library quietly
  # did nothing and reported success — a block dressed up as a no-op. The owner's
  # ruling (2026-07-30) makes a book on several bookshelves a legal state, so the
  # only genuine "already placed" is a placement on the *requested* bookshelf —
  # which is also the one the rung-4 unique index would reject. Everything else
  # gets its placement, and the caller is *informed* of the others via the
  # returned list.
  defp place_or_return_existing(user_id, book, shelf_name) do
    placements = Shelving.get_placements_for_book(user_id, book.id)

    case Enum.find(placements, &(&1.bookshelf.name == shelf_name)) do
      nil -> create_placement_for_existing(user_id, book, shelf_name, placements)
      placement -> {:ok, :already_placed, book, placement, placements}
    end
  end

  # Decision (#333): take the placement `place_book/3` just created rather than
  # re-querying for "the" placement. The re-query ended in `Repo.one()` and so
  # raised the moment the book was already on another bookshelf — precisely the
  # multi-shelf add this branch exists to perform. `place_book/3` hands back the
  # row it inserted, so the answer is unambiguous and one query cheaper; only
  # the bookshelf needs preloading for serialisation.
  defp create_placement_for_existing(user_id, book, shelf_name, existing) do
    case Shelving.place_book(user_id, book.id, shelf_name) do
      {:ok, placement} ->
        placement = Repo.preload(placement, :bookshelf)
        {:ok, :existing, book, placement, existing ++ [placement]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_isbn(isbn) when is_nil(isbn) or isbn == "", do: {:error, :missing_isbn}
  defp require_isbn(isbn), do: {:ok, isbn}

  # The confirmed path is `create_work/2` plus a placement and its own event —
  # nothing more. All it has to do first is translate the resolver's atom-keyed
  # metadata into the string-keyed attrs the create transaction speaks.
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
  Merges a new edition (ISBN) into an existing work.

  Creates a non-primary `book_edition` row linked to `work_id`.

  Returns `{:ok, edition}` on success.
  Returns `{:error, :not_found}` when `work_id` does not exist.
  Returns `{:error, :isbn_not_found}` when the upstreams do not know the ISBN.
  Returns `{:error, :resolver_unavailable}` when they could not be asked.
  Returns `{:error, changeset}` on validation failure (e.g. duplicate ISBN).
  """
  @spec merge_edition(String.t(), map()) :: {:ok, BookEdition.t()} | {:error, term()}
  def merge_edition(work_id, attrs) do
    isbn = attrs[:isbn] || attrs["isbn"]
    format_label = attrs[:format_label] || attrs["format_label"]

    with {:ok, meta} <- resolve_for_write(isbn),
         book when not is_nil(book) <- Repo.get(Book, work_id) do
      insert_edition(book, isbn, format_label, work_id, meta)
    else
      # `resolve_for_write/1` has already said which of the two this is; the
      # old clause here overwrote both with `:isbn_not_found`, so a merge
      # attempted during a Google Books outage told the reader their ISBN was
      # not a book.
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  # Conflict rule (#341): the CALLER states `isbn` and `format_label`; the
  # RESOLVER fills everything else.
  #
  # This function used to keep only the ISBN, the work id, the caller's format
  # label and the provenance, throwing away every other field of the metadata it
  # had just paid an Open Library / Google Books round-trip for — so a merged
  # edition had no cover, publisher, page count or cross-reference id, and
  # nothing downstream could tell "this edition has no publisher" from "nobody
  # ever asked".
  #
  # The rule is the conservative one — fill only what would otherwise be null.
  # It cannot destroy anything: the insert only ever creates a NEW row (a
  # duplicate ISBN is rejected as `:duplicate_isbn`, never updated), so no value
  # a reader or an earlier resolve established is reachable from here.
  #
  # The caller's half is deliberately narrow rather than "caller wins on every
  # field". `StacksWeb.BookController.merge_format/2` hands this function the
  # raw request params, so honouring a caller-supplied `publisher`,
  # `open_library_id` or `google_books_id` would make
  # `POST /api/books/:id/merge-format` a mass-assignment hole over exactly the
  # columns that record where an ISBN's verification came from. `format_label`
  # ("Hardcover", "Slipcased") is the one field the endpoint documents as the
  # caller's to choose, and the resolver never supplies it.
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
      # merge_edition/2 only gets here after ISBNResolver.resolve/1 succeeded,
      # so the provenance is whichever source answered.
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
  Looks up an author row by exact `name`, inserting a new row if none
  exists. Returns `{:ok, nil}` for nil or empty input — used during
  enrichment, where Open Library / Google Books may legitimately not
  carry an author. Returns `{:error, changeset}` only on insert failure
  (e.g. row constraint).

  Exposed (rather than kept private) so `Stacks.Workers.EnrichBookJob`
  can link the resolver's author string to a real `op.authors` row when
  filling in a placeholder book's `author_id`.
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

  # `ISBNResolver.resolve/1` hands back atom-keyed metadata; the create
  # transaction speaks string-keyed attrs. Translating here — rather than
  # keeping a second copy of the insert — is what makes ONE create transaction
  # possible, and it is the single place a newly-resolved field has to be added
  # for every create path to carry it.
  #
  # `verification_source` is deliberately absent: `edition_attrs/2` derives it
  # from the `open_library_id` / `google_books_id` copied above, which is the
  # same answer `verification_source_from/1` gives for the metadata itself.
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

  @doc """
  The closed set of values `book_editions.verification_source` may hold.

  Public so callers and tests name the same list the CHECK constraint does
  rather than re-spelling the strings.
  """
  @spec verification_sources() :: [String.t()]
  def verification_sources, do: @verification_sources

  @doc """
  Derives an edition's ISBN provenance from resolver metadata (#335 D1).

  `Stacks.Books.ISBNResolver` races Open Library and Google Books and returns
  whichever answered first, identified by which cross-reference id it carries —
  `open_library_id` for Open Library, `google_books_id` for Google Books. When
  neither is present nothing external confirmed the ISBN, so the answer is
  `"barcode_unverified"`: the same conservative reading the backfill in
  `20260730200000` uses, and the reason the moderation fast path (which resolves
  no metadata at all) needs no special case here.

  Accepts a map keyed by either atoms (resolver metadata) or strings (book
  attrs), since both shapes reach the edition insert paths.
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
  Puts one raw `op.book_editions` row through the production changeset on its
  way to `Repo.insert_all/3`, and returns it with the changeset's normalised
  `isbn`. Raises `ArgumentError` if the row is one production could not write.

  `insert_all/3` is the right tool for a fixture — deterministic ids, fixed
  timestamps, one round trip — but it goes around
  `book_edition_changeset/2` entirely, which is how `seeds.exs` shipped three
  editions whose ISBN check digit was wrong and how those rows reached staging
  (Issue #339). Nothing caught it: unit tests build editions through the
  changeset, and the seed's own rows were never asked to satisfy it.

  So the seed keeps `insert_all/3` and gains the validation it was missing. A
  seed row that fails here fails loudly at seed time in every environment —
  dev, CI, preview, staging — instead of becoming a row that only a CHECK
  constraint years later discovers. That is the same bargain #329 struck for the
  test factory: a fixture may only build states a real write path can produce.

  `book_id` may be a dumped 16-byte UUID (what `Seeds.uuid/1` returns) or a
  string; either is accepted. Keys outside the changeset's cast list —
  `:id`, `:created_at`, `:updated_at` — are passed through untouched.
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
    # Rung-4 backstops. The validations above already reject both, so these only
    # fire when a value slips past them (a `put_change`, a future write path) —
    # turning what would be a raised Postgrex error into a changeset error.
    |> check_constraint(:isbn,
      name: :book_editions_isbn_ean13_checksum,
      message: "must be a valid ISBN-13 with a correct check digit"
    )
    |> check_constraint(:verification_source,
      name: :book_editions_verification_source_check,
      message: "is invalid"
    )
  end

  # Normalise any ISBN-10 input to ISBN-13 before storage so that
  # find_existing/1 (which always searches by ISBN-13) can round-trip
  # correctly. Without this, a title-search returning an ISBN-10 would be
  # stored as-is, find_existing would miss it, and re-inserts would hit the
  # unique constraint instead of deduplicating cleanly.
  # Only runs when the changeset is still valid (format + checksum already passed).
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
