defmodule Stacks.GDPR.Export do
  @moduledoc """
  GDPR data export. Collects all user-owned data from the operational schema
  and formats it for download (right to data portability).
  """

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Shelving.{Bookshelf, Placement, PlacementHistory}

  @doc """
  Exports all data for a user. Returns a JSON-serialisable map.
  The `_opts` parameter is reserved for future filtering options.
  """
  @spec export_user_data(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def export_user_data(user_id, _opts \\ []) do
    user = Accounts.get_user!(user_id)

    bookshelves =
      Bookshelf
      |> where([bs], bs.user_id == ^user_id)
      |> Repo.all()

    bookshelf_ids = Enum.map(bookshelves, & &1.id)

    placements =
      Placement
      |> where([p], p.bookshelf_id in ^bookshelf_ids)
      |> preload(book: :editions)
      |> Repo.all()

    histories =
      PlacementHistory
      |> where([h], h.from_bookshelf in ^bookshelf_ids or h.to_bookshelf in ^bookshelf_ids)
      |> Repo.all()

    export = %{
      exported_at: DateTime.utc_now(),
      user: %{
        id: user.id,
        email: user.email,
        display_name: user.display_name,
        role: user.role,
        profile_visibility: user.profile_visibility,
        age_verified: user.age_verified,
        consent_analytics: user.consent_analytics,
        consent_analytics_at: user.consent_analytics_at,
        created_at: user.created_at
      },
      bookshelves: Enum.map(bookshelves, &bookshelf_to_map/1),
      placements: Enum.map(placements, &placement_to_map/1),
      placement_history: Enum.map(histories, &history_to_map/1)
    }

    {:ok, export}
  rescue
    error -> {:error, error}
  end

  defp bookshelf_to_map(bookshelf) do
    %{
      id: bookshelf.id,
      name: bookshelf.name,
      visibility: bookshelf.visibility,
      created_at: bookshelf.created_at
    }
  end

  defp placement_to_map(placement) do
    %{
      id: placement.id,
      book_isbn:
        placement.book &&
          (Stacks.Books.primary_edition(placement.book) || %{isbn: nil}).isbn,
      book_title: placement.book && placement.book.title,
      bookshelf_id: placement.bookshelf_id,
      position: placement.position,
      placed_at: placement.placed_at,
      removed_at: placement.removed_at,
      formats: placement.formats,
      personal_rating: placement.personal_rating,
      notes: placement.notes
    }
  end

  defp history_to_map(history) do
    %{
      id: history.id,
      book_id: history.book_id,
      from_bookshelf: history.from_bookshelf,
      to_bookshelf: history.to_bookshelf,
      moved_at: history.moved_at
    }
  end
end
