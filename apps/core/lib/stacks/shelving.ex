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
  alias Stacks.Audit
  alias Stacks.Events
  alias Stacks.Shelving.{Bookshelf, Placement, PlacementHistory}

  # ── Bookshelf changeset constants ──────────────────────────────────
  @valid_bookshelf_names ~w(antilibrary library wishlist reading_pile looking_for_home)
  @valid_visibilities ~w(owner group platform)

  # ── Placement changeset constants ──────────────────────────────────
  @valid_reading_statuses ~w(to_read reading completed abandoned)

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
    :finished_at
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
  Places a book on a bookshelf for a user. Creates the bookshelf if it doesn't exist.
  Returns `{:ok, placement}` or `{:error, changeset}`.
  """
  @spec place_book(binary(), binary(), String.t()) ::
          {:ok, Placement.t()} | {:error, Ecto.Changeset.t()}
  def place_book(user_id, book_id, bookshelf_name) do
    bookshelf = get_or_create_bookshelf(user_id, bookshelf_name)

    Multi.new()
    |> Multi.insert(
      :placement,
      placement_changeset(%Placement{}, %{
        book_id: book_id,
        bookshelf_id: bookshelf.id
      })
    )
    |> Multi.run(:emit_event, fn _repo, %{placement: p} ->
      Events.emit_safe(%{
        event_type: "placement.created",
        aggregate_type: "placement",
        aggregate_id: p.id,
        payload: %{book_id: book_id, bookshelf: bookshelf_name}
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
  """
  @spec move_book(binary(), binary(), String.t()) ::
          {:ok, map()} | {:error, :unauthorized} | {:error, atom(), term(), map()}
  def move_book(placement_id, user_id, to_bookshelf_name) do
    placement = Repo.get!(Placement, placement_id) |> Repo.preload(:bookshelf)

    if placement.bookshelf.user_id != user_id do
      {:error, :unauthorized}
    else
      from_bookshelf = placement.bookshelf
      from_bookshelf_name = from_bookshelf.name
      to_bookshelf = get_or_create_bookshelf(user_id, to_bookshelf_name)

      Multi.new()
      |> Multi.update(
        :placement,
        placement_changeset(placement, %{bookshelf_id: to_bookshelf.id})
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
  end

  @doc """
  Moves a book to the "looking_for_home" bookshelf (abandon flow).
  """
  @spec abandon_book(binary(), binary()) ::
          {:ok, map()} | {:error, :unauthorized} | {:error, atom(), term(), map()}
  def abandon_book(placement_id, user_id) do
    move_book(placement_id, user_id, "looking_for_home")
  end

  @doc """
  Adds the book to the library bookshelf again (re-read flow).
  Creates a new placement rather than reusing the old one, and writes a
  PlacementHistory record capturing the move from the original bookshelf to
  the library bookshelf.
  """
  @spec reread_book(binary()) :: {:ok, Placement.t()} | {:error, Ecto.Changeset.t()}
  def reread_book(placement_id) do
    placement = Repo.get!(Placement, placement_id) |> Repo.preload(:bookshelf)
    user_id = placement.bookshelf.user_id
    original_bookshelf_id = placement.bookshelf.id
    library_bookshelf = get_or_create_bookshelf(user_id, "library")

    Multi.new()
    |> Multi.insert(
      :placement,
      placement_changeset(%Placement{}, %{
        book_id: placement.book_id,
        bookshelf_id: library_bookshelf.id
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
          {:ok, Placement.t()} | {:error, :unauthorized} | {:error, Ecto.Changeset.t()}
  def remove_book(placement_id, user_id) do
    placement = Repo.get!(Placement, placement_id) |> Repo.preload(:bookshelf)

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
          {:ok, Placement.t()} | {:error, :unauthorized} | {:error, Ecto.Changeset.t()}
  def update_placement_formats(placement_id, user_id, formats) when is_list(formats) do
    placement = Repo.get!(Placement, placement_id) |> Repo.preload(:bookshelf)

    if placement.bookshelf.user_id != user_id do
      {:error, :unauthorized}
    else
      placement
      |> placement_changeset(%{formats: formats})
      |> Repo.update()
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
    |> where([p], is_nil(p.removed_at))
    |> select([p, bs], %{book_id: p.book_id, bookshelf_name: bs.name})
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
        |> Repo.update()
    end
  end

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
        nil -> nil
        p -> Repo.preload(p, :bookshelf)
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

    Multi.new()
    |> Multi.update(:placement, reading_progress_changeset(placement, progress_attrs))
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
