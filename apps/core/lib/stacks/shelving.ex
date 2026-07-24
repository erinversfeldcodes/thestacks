defmodule Stacks.Shelving do
  @moduledoc """
  Shelving context — manages bookshelves, placements, and the history of
  book movements between bookshelves.

  All multi-step operations use `Ecto.Multi` to guarantee atomicity.
  """

  # Ecto.Multi uses an opaque MapSet internally; dialyzer cannot resolve the
  # opaque subterms after Multi.new() and fires call_without_opaque on every
  # chained call. This is a known false positive.
  @dialyzer :no_opaque

  import Ecto.Changeset
  import Ecto.Query

  alias Core.Repo
  alias Ecto.Multi
  alias Stacks.Accounts.User
  alias Stacks.Audit
  alias Stacks.Books
  alias Stacks.Books.Book
  alias Stacks.Events
  alias Stacks.Shelving.{Bookshelf, Placement, PlacementHistory, Shelf}

  # ── Bookshelf changeset constants ──────────────────────────────────
  @valid_bookshelf_names ~w(antilibrary library wishlist reading_pile looking_for_home)
  # Single-sourced from the canonical Audience ladder (#209). Evaluated at compile
  # time to the same literal list, so it stays usable in the ceiling GUARD clauses
  # below (`when visibility in @valid_visibilities`). A drift test asserts this list
  # equals the `Audience` proto enum's settable values (proto/…/visibility.proto).
  @valid_visibilities Stacks.Visibility.audience_levels()

  # ── Placement changeset constants ──────────────────────────────────
  @valid_reading_statuses ~w(to_read reading completed abandoned)

  # ── Reading-pile capacity (#276) ───────────────────────────────────
  # The single source of truth for the 50-book Reading Pile cap. The Elm
  # view must never re-derive or truncate to this number — enforcement
  # lives here, at the write path.
  @reading_pile_limit 50

  @placement_optional_fields [
    :position,
    :placed_at,
    :removed_at,
    :formats,
    :personal_rating,
    :notes,
    :visibility,
    :listing_mode,
    :listing_status,
    :listing_price_cents,
    :listing_min_price_cents,
    :reading_status,
    :current_page,
    :started_at,
    :finished_at,
    :shelf_id
  ]

  # ── Changeset functions (moved from schema modules) ────────────────

  @doc "Changeset for creating or updating a bookshelf."
  def bookshelf_changeset(bookshelf, attrs) do
    bookshelf
    |> cast(attrs, [:user_id, :name, :visibility, :visibility_group_id])
    |> validate_required([:user_id, :name])
    |> validate_inclusion(:name, @valid_bookshelf_names)
    |> validate_inclusion(:visibility, @valid_visibilities)
    |> unique_constraint([:user_id, :name])
  end

  @doc "Changeset for creating or updating a placement."
  def placement_changeset(placement, attrs) do
    placement
    |> cast(attrs, [:book_id, :bookshelf_id | @placement_optional_fields])
    |> validate_required([:book_id, :bookshelf_id])
    |> validate_inclusion(:visibility, @valid_visibilities)
    |> validate_number(:personal_rating, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> unique_constraint([:book_id, :bookshelf_id],
      name: :bookshelf_placements_book_active_idx,
      message: "book is already on this bookshelf"
    )
    |> foreign_key_constraint(:book_id, message: "book does not exist")
    |> validate_inclusion(:reading_status, @valid_reading_statuses)
    |> validate_number(:current_page, greater_than_or_equal_to: 0)
    |> put_placed_at()
  end

  @doc "Changeset for updating reading progress fields only."
  def reading_progress_changeset(placement, attrs) do
    placement
    |> cast(attrs, [:reading_status, :current_page, :started_at, :finished_at])
    |> validate_required([:reading_status])
    |> validate_inclusion(:reading_status, @valid_reading_statuses)
    |> validate_number(:current_page, greater_than_or_equal_to: 0)
  end

  @doc "Changeset for recording a bookshelf move."
  def placement_history_changeset(history, attrs) do
    history
    |> cast(attrs, [:book_id, :from_bookshelf, :to_bookshelf, :moved_at])
    |> validate_required([:book_id, :from_bookshelf, :to_bookshelf])
    |> put_moved_at()
  end

  defp put_placed_at(%Ecto.Changeset{changes: changes} = changeset) do
    case Map.get(changes, :placed_at) do
      nil -> put_change(changeset, :placed_at, DateTime.utc_now())
      _ -> changeset
    end
  end

  defp put_moved_at(%Ecto.Changeset{changes: changes} = changeset) do
    case Map.get(changes, :moved_at) do
      nil -> put_change(changeset, :moved_at, DateTime.utc_now())
      _ -> changeset
    end
  end

  @doc """
  Returns true if the user has at least one active (non-removed) placement for
  the given book on any of their bookshelves. Used for duplicate detection
  during the upload identification flow.
  """
  @spec book_on_any_shelf?(binary(), binary()) :: boolean()
  def book_on_any_shelf?(user_id, book_id) do
    from(p in Placement,
      join: s in Bookshelf,
      on: s.id == p.bookshelf_id,
      where: s.user_id == ^user_id and p.book_id == ^book_id and is_nil(p.removed_at)
    )
    |> Repo.exists?()
  end

  @doc """
  Returns the bookshelf struct for the given user and bookshelf name, with the
  user association preloaded. Returns `nil` if the bookshelf does not exist.
  """
  @spec get_bookshelf(binary(), String.t()) :: Bookshelf.t() | nil
  def get_bookshelf(user_id, bookshelf_name) do
    Bookshelf
    |> where([b], b.user_id == ^user_id and b.name == ^bookshelf_name)
    |> preload(:user)
    |> Repo.one()
  end

  @doc """
  Returns all of a user's bookshelves ordered by name, each as a `%{name, visibility}`
  map. Used by the privacy settings screen to seed the current per-shelf visibility
  so a returning user sees their saved values rather than defaults.
  """
  @spec list_user_bookshelves(binary()) :: [%{name: String.t(), visibility: String.t()}]
  def list_user_bookshelves(user_id) do
    Bookshelf
    |> where([b], b.user_id == ^user_id)
    |> order_by([b], b.name)
    |> select([b], %{name: b.name, visibility: b.visibility})
    |> Repo.all()
  end

  @doc """
  Returns all active (non-removed) placements for a user on the named bookshelf,
  with books preloaded.
  """
  @spec get_bookshelf_books(binary(), String.t()) :: [Placement.t()]
  def get_bookshelf_books(user_id, bookshelf_name) do
    Placement
    |> join(:inner, [p], bs in Bookshelf,
      on: p.bookshelf_id == bs.id and bs.user_id == ^user_id and bs.name == ^bookshelf_name
    )
    |> where([p], is_nil(p.removed_at))
    |> order_by([p], [p.position, p.placed_at])
    |> preload(book: [:author, :editions])
    |> Repo.all()
  end

  @doc """
  Searches the viewer's own collection by book title (#285).

  Returns up to `:limit` (default 20) distinct books the user has an ACTIVE
  (non-removed) placement of, whose title matches the full-text query. The raw
  query is passed straight to `plainto_tsquery` via a bound param — injection
  safety comes from Ecto param binding + `plainto_tsquery` treating its input as
  plain text (the #291/#296 rationale), NOT from stripping characters. `title_tsv`
  is unqualified: only `op.books` carries that generated column, so it resolves
  unambiguously across the placement/bookshelf joins. Author + editions are
  preloaded for search-hit serialization.
  """
  @spec search_collection(binary(), String.t(), keyword()) :: [Book.t()]
  def search_collection(user_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Book
    |> join(:inner, [b], p in Placement, on: p.book_id == b.id and is_nil(p.removed_at))
    |> join(:inner, [b, p], bs in Bookshelf,
      on: p.bookshelf_id == bs.id and bs.user_id == ^user_id
    )
    |> where([b], fragment("title_tsv @@ plainto_tsquery('english', ?)", ^query))
    |> distinct(true)
    |> limit(^limit)
    |> preload([:author, :editions])
    |> Repo.all()
  end

  @doc """
  Builds "looking for a home" discovery labels for the given book ids (#285).

  Returns a map `%{book_id => %{source: "looking_for_home", owner_handle: handle}}`
  for every book with an always-visible `looking_for_home` placement — one whose
  `listing_status` is `"active"` (the `Stacks.Visibility` marketplace exception,
  the only shape that surfaces a placement regardless of its visibility). The
  owner's public handle rides the existing public-handle exposure; no price is
  attached (the LFH advert has no price — the marketplace listing carries that).
  When several such placements exist for one book, the most recently placed wins.
  Books with no active LFH placement are absent from the map.
  """
  @spec looking_for_home_labels([binary()]) :: %{binary() => map()}
  def looking_for_home_labels([]), do: %{}

  def looking_for_home_labels(book_ids) when is_list(book_ids) do
    Placement
    |> join(:inner, [p], bs in Bookshelf, on: p.bookshelf_id == bs.id)
    |> join(:inner, [p, bs], u in assoc(bs, :user))
    |> where(
      [p, bs],
      bs.name == "looking_for_home" and p.listing_status == "active" and
        is_nil(p.removed_at) and p.book_id in ^book_ids
    )
    |> order_by([p], desc: p.placed_at)
    |> select([p, bs, u], {p.book_id, u.handle})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {book_id, handle}, acc ->
      Map.put_new(acc, book_id, %{source: "looking_for_home", owner_handle: handle || ""})
    end)
  end

  @doc "Returns all users who have the given book on their wishlist."
  @spec users_with_book_on_wishlist(binary()) :: [User.t()]
  def users_with_book_on_wishlist(book_id) do
    from(u in User,
      join: bs in Bookshelf,
      on: bs.user_id == u.id and bs.name == "wishlist",
      join: p in Placement,
      on: p.bookshelf_id == bs.id and p.book_id == ^book_id,
      where: is_nil(p.removed_at),
      distinct: true
    )
    |> Repo.all(prefix: "op")
  end

  @doc """
  Returns the maximum number of active placements allowed on a `reading_pile`
  bookshelf (#276). Defined once here — the write path enforces it; views must
  not truncate to it.
  """
  @spec reading_pile_limit() :: pos_integer()
  def reading_pile_limit, do: @reading_pile_limit

  @doc """
  Places a book on a bookshelf for a user. Creates the bookshelf if it doesn't exist.
  Returns `{:ok, placement}`, `{:error, changeset}`, or `{:error, :reading_pile_full}`
  when the placement would take the reading pile past #{@reading_pile_limit} books.
  """
  @spec place_book(binary(), binary(), String.t()) ::
          {:ok, Placement.t()} | {:error, Ecto.Changeset.t() | :reading_pile_full}
  def place_book(user_id, book_id, bookshelf_name) do
    bookshelf = get_or_create_bookshelf(user_id, bookshelf_name)

    default_shelf = get_or_create_default_shelf(bookshelf.id)
    visibility_tier = lookup_book_visibility_tier(book_id)

    Multi.new()
    |> Multi.run(:reading_pile_capacity, fn repo, _changes ->
      check_reading_pile_capacity(repo, bookshelf)
    end)
    |> Multi.insert(
      :placement,
      placement_changeset(%Placement{}, %{
        book_id: book_id,
        bookshelf_id: bookshelf.id,
        shelf_id: default_shelf.id
      })
    )
    |> Multi.run(:emit_event, fn _repo, %{placement: p} ->
      Events.emit_safe(%{
        event_type: "placement.created",
        aggregate_type: "placement",
        aggregate_id: p.id,
        payload: %{
          book_id: book_id,
          bookshelf: bookshelf_name,
          visibility_tier: visibility_tier
        }
      })

      {:ok, p}
    end)
    |> Multi.run(:audit, fn _repo, %{placement: p} ->
      Audit.log(user_id, "placement.created",
        resource_type: "placement",
        resource_id: p.id,
        metadata: %{book_id: book_id, bookshelf: bookshelf_name}
      )
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{placement: placement}} -> {:ok, placement}
      {:error, :placement, changeset, _} -> {:error, changeset}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  @doc """
  Moves a book placement to a new bookshelf. Verifies ownership.
  Creates a PlacementHistory record. Uses Ecto.Multi for atomicity.
  A move into a full reading pile fails with
  `{:error, :reading_pile_capacity, :reading_pile_full, _}`.
  """
  @spec move_book(binary(), binary(), String.t()) ::
          {:ok, map()}
          | {:error, :unauthorized | :not_found}
          | {:error, atom(), term(), map()}
  def move_book(placement_id, user_id, to_bookshelf_name) do
    case Repo.get(Placement, placement_id) do
      nil ->
        {:error, :not_found}

      placement ->
        placement = Repo.preload(placement, :bookshelf)

        cond do
          placement.bookshelf.user_id != user_id ->
            {:error, :unauthorized}

          placement.bookshelf.name == to_bookshelf_name ->
            # Same-bookshelf "move" is a no-op success. A user has at most one
            # bookshelf per name, so an equal name means the same bookshelf. The
            # Elm mover already excludes the current bookshelf, so this path is
            # only reachable defensively (direct API/context call). Return the
            # placement UNCHANGED — no PlacementHistory row, no `placement.moved`
            # event, no audit entry, and (critically) WITHOUT the shelf_id reset
            # the Multi below would perform, which would yank a book off a
            # non-default shelf onto position 0 on a self-move. Shaped as
            # `{:ok, %{placement: _}}` to match the Multi result the controller
            # unwraps.
            {:ok, %{placement: placement}}

          true ->
            do_move_book(placement, user_id, to_bookshelf_name)
        end
    end
  end

  defp do_move_book(placement, user_id, to_bookshelf_name) do
    from_bookshelf = placement.bookshelf
    from_bookshelf_name = from_bookshelf.name
    to_bookshelf = get_or_create_bookshelf(user_id, to_bookshelf_name)
    # Browse lists placements through their physical shelf (op.shelves, #151),
    # so a move must re-home the placement onto a shelf of the DESTINATION
    # bookshelf — otherwise it stays visible on the source and never on the
    # target. Mirrors the creation-time assignment in place_book/3 and
    # reread_book/2: get-or-create the destination's default (position 0)
    # shelf. Resolved outside the Multi exactly as place_book/3 does; on a
    # capacity rejection the destination is a full reading_pile that already
    # owns its default shelf, so this is a no-op read and no write precedes
    # the rejection.
    to_shelf = get_or_create_default_shelf(to_bookshelf.id)

    Multi.new()
    |> Multi.run(:reading_pile_capacity, fn repo, _changes ->
      check_move_capacity(repo, from_bookshelf, to_bookshelf)
    end)
    |> Multi.update(
      :placement,
      placement_changeset(placement, %{bookshelf_id: to_bookshelf.id, shelf_id: to_shelf.id})
    )
    |> Multi.insert(:history, fn _ ->
      placement_history_changeset(%PlacementHistory{}, %{
        book_id: placement.book_id,
        from_bookshelf: from_bookshelf.id,
        to_bookshelf: to_bookshelf.id,
        moved_at: DateTime.utc_now()
      })
    end)
    |> Multi.run(:emit_event, fn _repo, %{placement: p} ->
      Events.emit_safe(%{
        event_type: "placement.moved",
        aggregate_type: "placement",
        aggregate_id: p.id,
        payload: %{from_bookshelf: from_bookshelf_name, to_bookshelf: to_bookshelf_name}
      })

      {:ok, p}
    end)
    |> Multi.run(:audit, fn _repo, %{placement: p} ->
      Audit.log(user_id, "placement.moved",
        resource_type: "placement",
        resource_id: p.id,
        metadata: %{from_bookshelf: from_bookshelf_name, to_bookshelf: to_bookshelf_name}
      )
    end)
    |> Repo.transaction()
  end

  @doc """
  Moves a book to the "looking_for_home" bookshelf (abandon flow).
  """
  @spec abandon_book(binary(), binary()) ::
          {:ok, map()}
          | {:error, :unauthorized | :not_found}
          | {:error, atom(), term(), map()}
  def abandon_book(placement_id, user_id) do
    move_book(placement_id, user_id, "looking_for_home")
  end

  @doc """
  Adds the book to the library bookshelf again (re-read flow).
  Creates a new placement rather than reusing the old one, and writes a
  PlacementHistory record capturing the move from the original bookshelf to
  the library bookshelf.
  """
  @spec reread_book(binary(), binary()) ::
          {:ok, Placement.t()}
          | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def reread_book(placement_id, user_id) do
    case Repo.get(Placement, placement_id) do
      nil ->
        {:error, :not_found}

      placement ->
        placement = Repo.preload(placement, :bookshelf)

        if placement.bookshelf.user_id != user_id do
          {:error, :unauthorized}
        else
          do_reread_book(placement, user_id)
        end
    end
  end

  defp do_reread_book(placement, user_id) do
    original_bookshelf_id = placement.bookshelf.id
    library_bookshelf = get_or_create_bookshelf(user_id, "library")
    default_shelf = get_or_create_default_shelf(library_bookshelf.id)

    Multi.new()
    |> Multi.insert(
      :placement,
      placement_changeset(%Placement{}, %{
        book_id: placement.book_id,
        bookshelf_id: library_bookshelf.id,
        shelf_id: default_shelf.id
      })
    )
    |> Multi.insert(:history, fn _ ->
      placement_history_changeset(%PlacementHistory{}, %{
        book_id: placement.book_id,
        from_bookshelf: original_bookshelf_id,
        to_bookshelf: library_bookshelf.id,
        moved_at: DateTime.utc_now()
      })
    end)
    |> Multi.run(:emit_event, fn _repo, %{placement: p} ->
      Events.emit_safe(%{
        event_type: "placement.reread",
        aggregate_type: "placement",
        aggregate_id: p.id,
        payload: %{book_id: placement.book_id, to_bookshelf: "library"}
      })

      {:ok, p}
    end)
    |> Multi.run(:audit, fn _repo, %{placement: p} ->
      Audit.log(user_id, "placement.reread",
        resource_type: "placement",
        resource_id: p.id,
        metadata: %{book_id: placement.book_id, to_bookshelf: "library"}
      )
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{placement: new_placement}} -> {:ok, new_placement}
      {:error, :placement, changeset, _} -> {:error, changeset}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  @doc """
  Soft-deletes a placement by setting `removed_at` to now.
  Emits an event and logs an audit entry.
  """
  @spec remove_book(binary(), binary()) ::
          {:ok, Placement.t()}
          | {:error, :not_found | :unauthorized}
          | {:error, Ecto.Changeset.t()}
  def remove_book(placement_id, user_id) do
    case Repo.get(Placement, placement_id) do
      nil ->
        {:error, :not_found}

      placement ->
        do_remove_book(Repo.preload(placement, :bookshelf), user_id)
    end
  end

  defp do_remove_book(placement, user_id) do
    if placement.bookshelf.user_id != user_id do
      {:error, :unauthorized}
    else
      Multi.new()
      |> Multi.update(
        :placement,
        placement_changeset(placement, %{removed_at: DateTime.utc_now()})
      )
      |> Multi.run(:emit_event, fn _repo, %{placement: p} ->
        Events.emit_safe(%{
          event_type: "placement.removed",
          aggregate_type: "placement",
          aggregate_id: p.id,
          payload: %{book_id: p.book_id}
        })

        {:ok, p}
      end)
      |> Multi.run(:audit, fn _repo, %{placement: p} ->
        Audit.log(user_id, "placement.removed",
          resource_type: "placement",
          resource_id: p.id,
          metadata: %{book_id: p.book_id}
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{placement: p}} -> {:ok, p}
        {:error, :placement, changeset, _} -> {:error, changeset}
        {:error, _, reason, _} -> {:error, reason}
      end
    end
  end

  @doc """
  Updates the formats list for a placement. Verifies ownership.
  Returns `{:ok, placement}` or `{:error, :unauthorized}` or `{:error, changeset}`.

  Deprecated: prefer `Books.merge_edition/2` for new code. Kept for Elm frontend compatibility.
  """
  @spec update_placement_formats(binary(), binary(), [String.t()]) ::
          {:ok, Placement.t()}
          | {:error, :not_found | :unauthorized}
          | {:error, Ecto.Changeset.t()}
  def update_placement_formats(placement_id, user_id, formats) when is_list(formats) do
    case Repo.get(Placement, placement_id) do
      nil ->
        {:error, :not_found}

      placement ->
        placement = Repo.preload(placement, :bookshelf)

        if placement.bookshelf.user_id != user_id do
          {:error, :unauthorized}
        else
          placement
          |> placement_changeset(%{formats: formats})
          |> Repo.update()
        end
    end
  end

  @doc """
  Returns spine rendering data for a placement: formats (derived from
  edition format labels), page_count (from the primary edition), and
  wear level (derived from how many times the book has been moved).
  """
  @spec spine_data(binary()) :: map() | nil
  def spine_data(placement_id) do
    placement = Repo.get(Placement, placement_id) |> Repo.preload(book: :editions)

    case placement do
      nil ->
        nil

      p ->
        move_count =
          PlacementHistory
          |> where([h], h.book_id == ^p.book_id)
          |> Repo.aggregate(:count, :id)

        wear_level = compute_wear_level(move_count)

        editions = if p.book && is_list(p.book.editions), do: p.book.editions, else: []
        primary = if p.book, do: Stacks.Books.primary_edition(p.book), else: nil

        %{
          placement_id: placement_id,
          formats: editions |> Enum.map(& &1.format_label) |> Enum.reject(&is_nil/1),
          page_count: primary && primary.page_count,
          move_count: move_count,
          wear_level: wear_level
        }
    end
  end

  defp compute_wear_level(0), do: :new
  defp compute_wear_level(n) when n <= 2, do: :light
  defp compute_wear_level(n) when n <= 5, do: :moderate
  defp compute_wear_level(_), do: :heavy

  @doc """
  Returns the user's active (non-removed) placement for a specific book,
  with the bookshelf preloaded. Returns `nil` if no such placement exists.
  """
  @spec get_placement_for_book(binary(), binary()) :: Placement.t() | nil
  def get_placement_for_book(user_id, book_id) do
    Placement
    |> join(:inner, [p], bs in Bookshelf, on: p.bookshelf_id == bs.id and bs.user_id == ^user_id)
    |> where([p], p.book_id == ^book_id and is_nil(p.removed_at))
    |> preload(:bookshelf)
    |> Repo.one()
  end

  @doc """
  Returns a lightweight summary of all active placements for a user:
  each entry contains the book_id and the bookshelf name.
  """
  @spec get_user_placements_summary(binary()) :: [map()]
  def get_user_placements_summary(user_id) do
    Placement
    |> join(:inner, [p], bs in Bookshelf, on: p.bookshelf_id == bs.id and bs.user_id == ^user_id)
    |> join(:inner, [p], b in Book, on: b.id == p.book_id)
    |> where([p], is_nil(p.removed_at))
    |> select([p, bs, b], %{book_id: p.book_id, bookshelf_name: bs.name, title: b.title})
    |> Repo.all()
  end

  @doc """
  Updates the visibility of a bookshelf. Verifies ownership.
  Returns `{:ok, bookshelf}`, `{:error, :unauthorized}`, or `{:error, :not_found}`.
  """
  @spec update_bookshelf_visibility(binary(), binary(), String.t()) ::
          {:ok, Bookshelf.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_bookshelf_visibility(bookshelf_id, user_id, visibility) do
    case Repo.get(Bookshelf, bookshelf_id) do
      nil ->
        {:error, :not_found}

      %Bookshelf{user_id: owner_id} when owner_id != user_id ->
        {:error, :unauthorized}

      bookshelf ->
        bookshelf
        |> bookshelf_changeset(%{visibility: visibility})
        |> validate_bookshelf_profile_ceiling(user_id, visibility)
        |> Repo.update()
    end
  end

  @doc """
  Sets the visibility of a user's named bookshelf, resolving (and lazily
  creating) it by name. This is the UI/API path: the Elm settings page and the
  `PUT /api/bookshelves/:bookshelf_name/visibility` route identify shelves by
  their canonical name, never by UUID. Enforces the profile-visibility ceiling
  (#195) exactly as `update_bookshelf_visibility/3` does.
  """
  @spec set_bookshelf_visibility(binary(), String.t(), String.t()) ::
          {:ok, Bookshelf.t()} | {:error, Ecto.Changeset.t()}
  def set_bookshelf_visibility(user_id, bookshelf_name, visibility) do
    if visibility in @valid_visibilities do
      get_or_create_bookshelf(user_id, bookshelf_name)
      |> bookshelf_changeset(%{visibility: visibility})
      |> validate_bookshelf_profile_ceiling(user_id, visibility)
      |> Repo.update()
    else
      # SEC-5: reject an invalid visibility value BEFORE lazily creating the
      # shelf, so a 422 does not leave a stray empty bookshelf behind.
      {:error,
       %Bookshelf{user_id: user_id, name: bookshelf_name}
       |> cast(%{visibility: visibility}, [:visibility])
       |> validate_inclusion(:visibility, @valid_visibilities)}
    end
  end

  # A bookshelf may not be made more visible than the owner's profile ceiling
  # (US-10.2.1). Per Stacks.Visibility, only a "owner" profile acts as a hard
  # ceiling — it hides all content — so when the profile is "owner" the bookshelf
  # visibility must also be "owner". A "platform" profile imposes no additional
  # restriction beyond the bookshelf's own value. The error is added to the
  # changeset so callers get an Ecto.Changeset (HTTP 422 with visibility errors),
  # consistent with the other visibility validations. Only applied to otherwise-
  # valid visibility values so invalid-inclusion errors are surfaced normally.
  defp validate_bookshelf_profile_ceiling(changeset, user_id, visibility)
       when visibility in @valid_visibilities do
    profile_visibility =
      Repo.one(from(u in User, where: u.id == ^user_id, select: u.profile_visibility))

    if profile_visibility == "owner" and visibility != "owner" do
      # Count the bookshelf ceiling rejection (§12 telemetry, Issue #197). This
      # rejection path was added in #195; the counter is wired here so it fires
      # on the same definitive rule violation the changeset error marks.
      Stacks.Visibility.emit_ceiling_rejection(:bookshelf)

      add_error(
        changeset,
        :visibility,
        "is less restrictive than the profile visibility ceiling"
      )
    else
      changeset
    end
  end

  defp validate_bookshelf_profile_ceiling(changeset, _user_id, _visibility), do: changeset

  @doc """
  Updates the visibility of a placement. Verifies ownership and enforces that
  placement visibility is not less restrictive than the parent bookshelf.
  Returns `{:ok, placement}`, `{:error, :unauthorized}`, `{:error, :not_found}`,
  or `{:error, reason_string}` if the ceiling rule is violated.
  """
  @spec update_placement_visibility(binary(), binary(), String.t()) ::
          {:ok, Placement.t()}
          | {:error, :unauthorized | :not_found | String.t() | Ecto.Changeset.t()}
  def update_placement_visibility(placement_id, user_id, visibility) do
    placement =
      case Repo.get(Placement, placement_id) do
        nil -> nil
        p -> Repo.preload(p, :bookshelf)
      end

    case placement do
      nil ->
        {:error, :not_found}

      %Placement{bookshelf: %Bookshelf{user_id: owner_id}} when owner_id != user_id ->
        {:error, :unauthorized}

      %Placement{bookshelf: bookshelf} ->
        case Stacks.Visibility.validate_visibility_ceiling(
               visibility,
               bookshelf.visibility,
               :placement
             ) do
          :ok ->
            placement
            |> placement_changeset(%{visibility: visibility})
            |> Repo.update()

          {:error, reason} ->
            Stacks.Visibility.emit_ceiling_rejection(:placement)
            {:error, reason}
        end
    end
  end

  @doc """
  Updates the reading progress for a placement. Verifies ownership.

  Auto-sets `started_at` on the first transition to `:reading` (will not overwrite
  if already set). Auto-sets `finished_at` on transition to `:completed`.

  Emits `placement.reading_started` on the first `:reading` transition, and
  `placement.reading_completed` on the `:completed` transition.

  Returns `{:ok, placement}` or `{:error, :unauthorized | :not_found | changeset}`.
  """
  @spec update_reading_progress(binary(), binary(), map()) ::
          {:ok, Placement.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_reading_progress(placement_id, user_id, attrs) do
    placement =
      case Repo.get(Placement, placement_id) do
        # Preload the book's editions too: the page-count ceiling (below) lives
        # on the primary edition, not the placement, so we resolve it here.
        nil -> nil
        p -> Repo.preload(p, [:bookshelf, book: :editions])
      end

    case placement do
      nil -> {:error, :not_found}
      %Placement{bookshelf: %Bookshelf{user_id: id}} when id != user_id -> {:error, :unauthorized}
      %Placement{} -> do_update_reading_progress(placement, attrs)
    end
  end

  defp do_update_reading_progress(placement, attrs) do
    # Normalise to atom keys so that maybe_set_* helpers produce a
    # consistent key type regardless of whether attrs came from a
    # controller (string keys) or a context test (atom keys).
    key_map = %{
      "reading_status" => :reading_status,
      "current_page" => :current_page,
      "started_at" => :started_at,
      "finished_at" => :finished_at
    }

    atom_attrs =
      for {k, v} <- attrs, into: %{} do
        {if(is_atom(k), do: k, else: Map.get(key_map, k, k)), v}
      end

    new_status = Map.get(atom_attrs, :reading_status)
    is_first_reading = new_status == "reading" && is_nil(placement.started_at)
    is_completing = new_status == "completed"

    progress_attrs =
      atom_attrs
      |> maybe_set_started_at(is_first_reading)
      |> maybe_set_finished_at(is_completing)

    page_ceiling = placement_page_count(placement)

    Multi.new()
    |> Multi.update(
      :placement,
      placement
      |> reading_progress_changeset(progress_attrs)
      |> maybe_validate_page_ceiling(page_ceiling)
    )
    |> Multi.run(:emit_events, fn _repo, %{placement: updated} ->
      emit_reading_events(updated, is_first_reading, is_completing)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{placement: updated}} -> {:ok, updated}
      {:error, :placement, cs, _} -> {:error, cs}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  # Reading progress may not exceed the book's primary-edition page count when
  # that count is KNOWN. Page count lives on the edition, not the placement, so
  # the ceiling is enforced at the context layer (here) rather than in
  # `reading_progress_changeset/2`, which has no access to the book. When the
  # page count is unknown (no edition, or an edition with a null/zero
  # page_count) NO ceiling is applied — a reader is never blocked on missing
  # catalogue metadata (permissive by design).
  defp placement_page_count(%Placement{book: %Book{} = book}) do
    case Books.primary_edition(book) do
      %{page_count: pc} when is_integer(pc) and pc > 0 -> pc
      _ -> nil
    end
  end

  defp placement_page_count(_placement), do: nil

  defp maybe_validate_page_ceiling(changeset, page_count) when is_integer(page_count) do
    validate_number(changeset, :current_page, less_than_or_equal_to: page_count)
  end

  defp maybe_validate_page_ceiling(changeset, _page_count), do: changeset

  defp emit_reading_events(placement, is_first_reading, is_completing) do
    if is_first_reading do
      Events.emit_safe(%{
        event_type: "placement.reading_started",
        aggregate_type: "placement",
        aggregate_id: placement.id,
        payload: %{book_id: placement.book_id}
      })
    end

    if is_completing do
      Events.emit_safe(%{
        event_type: "placement.reading_completed",
        aggregate_type: "placement",
        aggregate_id: placement.id,
        payload: %{book_id: placement.book_id}
      })
    end

    {:ok, placement}
  end

  @doc """
  Returns all active placements for a user with `reading_status = 'reading'`,
  ordered by `updated_at DESC`.
  """
  @spec list_in_progress(binary()) :: [Placement.t()]
  def list_in_progress(user_id) do
    Placement
    |> join(:inner, [p], bs in Bookshelf, on: p.bookshelf_id == bs.id and bs.user_id == ^user_id)
    |> where([p], p.reading_status == "reading" and is_nil(p.removed_at))
    |> order_by([p], desc: p.updated_at)
    |> Repo.all()
  end

  defp maybe_set_started_at(attrs, true), do: Map.put(attrs, :started_at, DateTime.utc_now())
  defp maybe_set_started_at(attrs, false), do: attrs

  defp maybe_set_finished_at(attrs, true), do: Map.put(attrs, :finished_at, DateTime.utc_now())
  defp maybe_set_finished_at(attrs, false), do: attrs

  # ── Shelf functions ──────────────────────────────────────────────────

  @doc "Returns all shelves for a bookshelf in ascending position order."
  @spec list_shelves(binary()) :: [Shelf.t()]
  def list_shelves(bookshelf_id) do
    Shelf
    |> where([s], s.bookshelf_id == ^bookshelf_id)
    |> order_by([s], s.position)
    |> Repo.all()
  end

  @doc "Creates a new shelf on a bookshelf at the next available position."
  @spec create_shelf(binary(), binary()) :: {:ok, Shelf.t()} | {:error, :unauthorized}
  def create_shelf(bookshelf_id, user_id) do
    case Repo.get(Bookshelf, bookshelf_id) do
      nil ->
        {:error, :unauthorized}

      %Bookshelf{user_id: owner_id} when owner_id != user_id ->
        {:error, :unauthorized}

      _bookshelf ->
        max_pos = shelf_max_position(bookshelf_id)

        %Shelf{}
        |> shelf_changeset(%{bookshelf_id: bookshelf_id, position: max_pos + 1})
        |> Repo.insert()
    end
  end

  @doc "Deletes a shelf if empty. Returns :not_empty if it has active placements."
  @spec delete_shelf(binary(), binary()) ::
          :ok | {:error, :unauthorized | :not_found | :not_empty}
  def delete_shelf(shelf_id, user_id) do
    shelf = Repo.get(Shelf, shelf_id) |> Repo.preload(:bookshelf)

    cond do
      is_nil(shelf) ->
        {:error, :not_found}

      shelf.bookshelf.user_id != user_id ->
        {:error, :unauthorized}

      shelf_has_active_placements?(shelf_id) ->
        {:error, :not_empty}

      true ->
        Repo.delete!(shelf)
        :ok
    end
  end

  @doc "Reorders shelves to match the given list of IDs."
  @spec reorder_shelves(binary(), binary(), [binary()]) ::
          :ok | {:error, :unauthorized | :invalid_ids}
  def reorder_shelves(bookshelf_id, user_id, shelf_ids_in_order) do
    case Repo.get(Bookshelf, bookshelf_id) do
      nil ->
        {:error, :unauthorized}

      %Bookshelf{user_id: owner_id} when owner_id != user_id ->
        {:error, :unauthorized}

      _bookshelf ->
        do_reorder_shelves(bookshelf_id, shelf_ids_in_order)
    end
  end

  @doc "Moves a placement to a different shelf within the same bookshelf."
  @spec move_placement_to_shelf(binary(), binary(), binary()) ::
          {:ok, Placement.t()} | {:error, :not_found | :unauthorized | :wrong_bookshelf}
  def move_placement_to_shelf(placement_id, shelf_id, user_id) do
    with placement when not is_nil(placement) <- Repo.get(Placement, placement_id),
         shelf when not is_nil(shelf) <- Repo.get(Shelf, shelf_id) do
      placement = Repo.preload(placement, :bookshelf)

      cond do
        placement.bookshelf.user_id != user_id ->
          {:error, :unauthorized}

        shelf.bookshelf_id != placement.bookshelf_id ->
          {:error, :wrong_bookshelf}

        true ->
          placement
          |> placement_changeset(%{shelf_id: shelf_id})
          |> Repo.update()
      end
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Returns shelves with preloaded placements for a bookshelf."
  @spec get_bookshelf_shelves(binary(), String.t()) :: [Shelf.t()]
  def get_bookshelf_shelves(user_id, bookshelf_name) do
    Shelf
    |> join(:inner, [s], bs in Bookshelf,
      on: s.bookshelf_id == bs.id and bs.user_id == ^user_id and bs.name == ^bookshelf_name
    )
    |> order_by([s], s.position)
    |> preload(placements: ^active_placements_query())
    |> Repo.all()
  end

  defp active_placements_query do
    from(p in Placement,
      where: is_nil(p.removed_at),
      order_by: [p.position, p.placed_at],
      # Preload bookshelf + its owner so Visibility.resolve_visibility/2 reuses them
      # (profile ceiling + bookshelf ceiling) instead of firing a query per placement
      # — the public /u/:handle/bookshelves/:name browse resolves every row.
      preload: [book: [:author, :editions], bookshelf: :user]
    )
  end

  @doc """
  Changeset for creating a shelf. Declares the `(bookshelf_id, position)` unique
  constraint (DB index `shelves_bookshelf_id_position_index`, migration
  20260330130609) so a duplicate insert surfaces as `{:error, changeset}` instead
  of raising `Ecto.ConstraintError`. `get_or_create_default_shelf/1` depends on
  this: its race fallback (`{:error, _} -> get_by!`) only fires when the losing
  concurrent insert returns an error tuple rather than raising.
  """
  @spec shelf_changeset(Shelf.t(), map()) :: Ecto.Changeset.t()
  def shelf_changeset(shelf, attrs) do
    shelf
    |> cast(attrs, [:bookshelf_id, :position, :created_at])
    |> validate_required([:bookshelf_id, :position])
    |> unique_constraint([:bookshelf_id, :position])
    |> put_created_at()
  end

  defp put_created_at(%Ecto.Changeset{changes: changes} = changeset) do
    case Map.get(changes, :created_at) do
      nil -> put_change(changeset, :created_at, DateTime.utc_now())
      _ -> changeset
    end
  end

  defp shelf_max_position(bookshelf_id) do
    Shelf
    |> where([s], s.bookshelf_id == ^bookshelf_id)
    |> Repo.aggregate(:max, :position) || -1
  end

  defp shelf_has_active_placements?(shelf_id) do
    Placement
    |> where([p], p.shelf_id == ^shelf_id and is_nil(p.removed_at))
    |> Repo.exists?()
  end

  defp do_reorder_shelves(bookshelf_id, shelf_ids_in_order) do
    existing_ids =
      Shelf
      |> where([s], s.bookshelf_id == ^bookshelf_id)
      |> select([s], s.id)
      |> Repo.all()
      |> MapSet.new()

    given_ids = MapSet.new(shelf_ids_in_order)

    if MapSet.equal?(existing_ids, given_ids) do
      n = length(shelf_ids_in_order)

      result =
        Repo.transaction(fn ->
          # Phase 1: shift all positions up by n to vacate the 0..n-1 range,
          # preventing unique-constraint conflicts during sequential updates.
          Repo.update_all(
            from(s in Shelf, where: s.bookshelf_id == ^bookshelf_id),
            inc: [position: n]
          )

          # Phase 2: set each shelf to its final position.
          apply_shelf_positions(shelf_ids_in_order)
        end)

      case result do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_ids}
    end
  end

  defp apply_shelf_positions(shelf_ids_in_order) do
    Enum.each(Enum.with_index(shelf_ids_in_order), fn {id, pos} ->
      Repo.update_all(from(s in Shelf, where: s.id == ^id), set: [position: pos])
    end)
  end

  defp get_or_create_default_shelf(bookshelf_id) do
    case Repo.get_by(Shelf, bookshelf_id: bookshelf_id, position: 0) do
      nil ->
        changeset =
          %Shelf{}
          |> shelf_changeset(%{bookshelf_id: bookshelf_id, position: 0})

        case Repo.insert(changeset) do
          {:ok, shelf} -> shelf
          {:error, _} -> Repo.get_by!(Shelf, bookshelf_id: bookshelf_id, position: 0)
        end

      shelf ->
        shelf
    end
  end

  # Looks up the book's visibility_tier so downstream event consumers (e.g. the
  # GDPR/age-gate filter on the public timeline) can decide whether to surface
  # this placement without a follow-up book lookup. Returns nil if the book
  # cannot be loaded — the placement insert that follows will fail the FK check
  # in that case, so a nil here is harmless.
  defp lookup_book_visibility_tier(book_id) do
    case Repo.get(Book, book_id) do
      %Book{visibility_tier: tier} -> tier
      _ -> nil
    end
  end

  # Enforces the reading-pile cap (#276) inside the write transaction.
  #
  # Concurrency decision: a count-check inside the Ecto.Multi transaction,
  # preceded by `SELECT ... FOR UPDATE` on the bookshelf row. A bare count
  # could race — under READ COMMITTED two concurrent placements could each
  # count 49 and both insert, ending at 51. Locking the user's single
  # reading_pile bookshelf row serializes placements into that pile: the
  # second transaction blocks on the lock until the first commits, then its
  # count sees the true total and rejects. A DB CHECK constraint cannot
  # express a cross-row count, and a trigger would duplicate this domain rule
  # in SQL; per-user pile writes are far too infrequent for row-lock
  # serialization to matter for throughput.
  #
  # Grandfather decision: the check asks "would this ADD exceed the cap"
  # (>= limit before inserting), so piles that already exceed 50 keep every
  # book — no data loss, no hiding — but accept no new placements until they
  # drop below the limit. (Dev-DB survey 2026-07-22: largest pile was 4, so
  # no user is currently grandfathered.)
  defp check_reading_pile_capacity(repo, %Bookshelf{name: "reading_pile", id: bookshelf_id}) do
    repo.one(from(b in Bookshelf, where: b.id == ^bookshelf_id, lock: "FOR UPDATE"))

    active_count =
      repo.aggregate(
        from(p in Placement, where: p.bookshelf_id == ^bookshelf_id and is_nil(p.removed_at)),
        :count
      )

    if active_count >= @reading_pile_limit do
      {:error, :reading_pile_full}
    else
      {:ok, active_count}
    end
  end

  defp check_reading_pile_capacity(_repo, %Bookshelf{}), do: {:ok, :not_limited}

  # Only cross-bookshelf moves reach here: `move_book/3` short-circuits a
  # same-bookshelf "move" to a no-op success before `do_move_book/3` (and thus
  # this check) ever runs. So the cap is evaluated purely against the
  # destination — a same-bookshelf reorganisation of a full (or grandfathered
  # over-limit) pile never trips it because it never gets this far.
  defp check_move_capacity(repo, _from_bookshelf, to_bookshelf),
    do: check_reading_pile_capacity(repo, to_bookshelf)

  defp get_or_create_bookshelf(user_id, bookshelf_name) do
    case Repo.get_by(Bookshelf, user_id: user_id, name: bookshelf_name) do
      nil ->
        %Bookshelf{}
        |> bookshelf_changeset(%{user_id: user_id, name: bookshelf_name})
        |> Repo.insert!()

      bookshelf ->
        bookshelf
    end
  end
end
