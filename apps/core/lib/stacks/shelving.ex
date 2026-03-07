defmodule Stacks.Shelving do
  @moduledoc """
  Shelving context — manages bookshelves, placements, and the history of
  book movements between shelves.

  All multi-step operations use `Ecto.Multi` to guarantee atomicity.
  """

  import Ecto.Query

  alias Core.Repo
  alias Ecto.Multi
  alias Stacks.Audit
  alias Stacks.Events
  alias Stacks.Shelving.{Bookshelf, Placement, PlacementHistory}

  @doc """
  Returns all active (non-removed) placements for a user on the named shelf,
  with books preloaded.
  """
  @spec get_shelf_books(binary(), String.t()) :: [Placement.t()]
  def get_shelf_books(user_id, shelf_name) do
    Placement
    |> join(:inner, [p], bs in Bookshelf,
      on: p.bookshelf_id == bs.id and bs.user_id == ^user_id and bs.name == ^shelf_name
    )
    |> where([p], is_nil(p.removed_at))
    |> order_by([p], [p.position, p.placed_at])
    |> preload(:book)
    |> Repo.all()
  end

  @doc """
  Places a book on a shelf for a user. Creates the bookshelf if it doesn't exist.
  Returns `{:ok, placement}` or `{:error, changeset}`.
  """
  @spec place_book(binary(), binary(), String.t()) ::
          {:ok, Placement.t()} | {:error, Ecto.Changeset.t()}
  def place_book(user_id, book_id, shelf_name) do
    shelf = get_or_create_shelf(user_id, shelf_name)

    Multi.new()
    |> Multi.insert(
      :placement,
      Placement.changeset(%Placement{}, %{
        book_id: book_id,
        bookshelf_id: shelf.id
      })
    )
    |> Multi.run(:emit_event, fn _repo, %{placement: p} ->
      Events.emit(%{
        event_type: "placement.created",
        aggregate_type: "placement",
        aggregate_id: p.id,
        payload: %{book_id: book_id, shelf: shelf_name}
      })

      {:ok, p}
    end)
    |> Multi.run(:audit, fn _repo, %{placement: p} ->
      Audit.log(user_id, "placement.created",
        resource_type: "placement",
        resource_id: p.id,
        metadata: %{book_id: book_id, shelf: shelf_name}
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
  Moves a book placement to a new shelf. Verifies ownership.
  Creates a PlacementHistory record. Uses Ecto.Multi for atomicity.
  """
  @spec move_book(binary(), binary(), String.t()) ::
          {:ok, map()} | {:error, :unauthorized} | {:error, atom(), term(), map()}
  def move_book(placement_id, user_id, to_shelf_name) do
    placement = Repo.get!(Placement, placement_id) |> Repo.preload(:bookshelf)

    if placement.bookshelf.user_id != user_id do
      {:error, :unauthorized}
    else
      from_shelf = placement.bookshelf
      from_shelf_name = from_shelf.name
      to_shelf = get_or_create_shelf(user_id, to_shelf_name)

      Multi.new()
      |> Multi.update(:placement, Placement.changeset(placement, %{bookshelf_id: to_shelf.id}))
      |> Multi.insert(:history, fn _ ->
        PlacementHistory.changeset(%PlacementHistory{}, %{
          book_id: placement.book_id,
          from_bookshelf: from_shelf.id,
          to_bookshelf: to_shelf.id,
          moved_at: DateTime.utc_now()
        })
      end)
      |> Multi.run(:emit_event, fn _repo, %{placement: p} ->
        Events.emit(%{
          event_type: "placement.moved",
          aggregate_type: "placement",
          aggregate_id: p.id,
          payload: %{from_shelf: from_shelf_name, to_shelf: to_shelf_name}
        })

        {:ok, p}
      end)
      |> Multi.run(:audit, fn _repo, %{placement: p} ->
        Audit.log(user_id, "placement.moved",
          resource_type: "placement",
          resource_id: p.id,
          metadata: %{from_shelf: from_shelf_name, to_shelf: to_shelf_name}
        )
      end)
      |> Repo.transaction()
    end
  end

  @doc """
  Moves a book to the "looking_for_home" shelf (abandon flow).
  """
  @spec abandon_book(binary(), binary()) ::
          {:ok, map()} | {:error, :unauthorized} | {:error, atom(), term(), map()}
  def abandon_book(placement_id, user_id) do
    move_book(placement_id, user_id, "looking_for_home")
  end

  @doc """
  Adds the book to the library shelf again (re-read flow).
  Creates a new placement rather than reusing the old one, and writes a
  PlacementHistory record capturing the move from the original shelf to
  the library shelf.
  """
  @spec reread_book(binary()) :: {:ok, Placement.t()} | {:error, Ecto.Changeset.t()}
  def reread_book(placement_id) do
    placement = Repo.get!(Placement, placement_id) |> Repo.preload(:bookshelf)
    user_id = placement.bookshelf.user_id
    original_bookshelf_id = placement.bookshelf.id
    library_shelf = get_or_create_shelf(user_id, "library")

    Multi.new()
    |> Multi.insert(
      :placement,
      Placement.changeset(%Placement{}, %{
        book_id: placement.book_id,
        bookshelf_id: library_shelf.id
      })
    )
    |> Multi.insert(:history, fn _ ->
      PlacementHistory.changeset(%PlacementHistory{}, %{
        book_id: placement.book_id,
        from_bookshelf: original_bookshelf_id,
        to_bookshelf: library_shelf.id,
        moved_at: DateTime.utc_now()
      })
    end)
    |> Multi.run(:emit_event, fn _repo, %{placement: p} ->
      Events.emit(%{
        event_type: "placement.reread",
        aggregate_type: "placement",
        aggregate_id: p.id,
        payload: %{book_id: placement.book_id, to_shelf: "library"}
      })

      {:ok, p}
    end)
    |> Multi.run(:audit, fn _repo, %{placement: p} ->
      Audit.log(user_id, "placement.reread",
        resource_type: "placement",
        resource_id: p.id,
        metadata: %{book_id: placement.book_id, to_shelf: "library"}
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
  @spec remove_book(binary(), binary()) :: {:ok, Placement.t()} | {:error, Ecto.Changeset.t()}
  def remove_book(placement_id, user_id) do
    placement = Repo.get!(Placement, placement_id)

    Multi.new()
    |> Multi.update(:placement, Placement.changeset(placement, %{removed_at: DateTime.utc_now()}))
    |> Multi.run(:emit_event, fn _repo, %{placement: p} ->
      Events.emit(%{
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

  @doc """
  Returns spine rendering data for a placement: page_count and wear level
  (derived from how many times the book has been moved).
  """
  @spec spine_data(binary()) :: map() | nil
  def spine_data(placement_id) do
    placement = Repo.get(Placement, placement_id) |> Repo.preload(:book)

    case placement do
      nil ->
        nil

      p ->
        move_count =
          PlacementHistory
          |> where([h], h.book_id == ^p.book_id)
          |> Repo.aggregate(:count, :id)

        wear_level = compute_wear_level(move_count)

        %{
          placement_id: placement_id,
          page_count: p.book && p.book.page_count,
          move_count: move_count,
          wear_level: wear_level
        }
    end
  end

  defp compute_wear_level(0), do: :new
  defp compute_wear_level(n) when n <= 2, do: :light
  defp compute_wear_level(n) when n <= 5, do: :moderate
  defp compute_wear_level(_), do: :heavy

  defp get_or_create_shelf(user_id, shelf_name) do
    case Repo.get_by(Bookshelf, user_id: user_id, name: shelf_name) do
      nil ->
        %Bookshelf{}
        |> Bookshelf.changeset(%{user_id: user_id, name: shelf_name})
        |> Repo.insert!()

      shelf ->
        shelf
    end
  end
end
