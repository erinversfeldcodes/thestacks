defmodule Stacks.DataCorrection.UnmergeEdition do
  @moduledoc """
  Splits a wrongly merged edition back off its work (376) —
  `merge_edition/2` is otherwise a one-way door, and a wrong merge makes
  the ISBN resolve to the wrong title for every reader who scans it.
  Owner-side data correction, not public UI (2026-07-30 ruling).

  Changes exactly two columns of one row: `book_id` → a newly minted work
  holding only this edition (title/author supplied by the operator), and
  `is_primary` → true. Placements naming the split edition are re-pointed
  to the new work in the same transaction. It does NOT touch the old
  work's other editions, delete anything, or attempt provider re-vetting —
  the new work is deliberately minimal and enriches like any other.
  """

  @behaviour Stacks.DataCorrection.Targeted

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Books
  alias Stacks.Books.Book
  alias Stacks.Books.BookDetailCache
  alias Stacks.Books.BookEdition
  alias Stacks.DataCorrection.Column
  alias Stacks.Shelving.Placement

  @work {"op.book_editions", "book_id"}
  @primary {"op.book_editions", "is_primary"}

  @impl true
  def name, do: "unmerge_edition"

  @impl true
  def resource_type, do: "book_edition"

  @impl true
  def scope(%{edition_id: edition_id}),
    do:
      "the single op.book_editions row #{edition_id} — its book_id and is_primary, " <>
        "plus one new op.books row to hold it. Placements that NAME this edition " <>
        "follow it to the new work (#396); every other placement is untouched."

  @impl true
  def reversibility,
    do:
      {:reversible,
       "the audit row keeps the work the edition left, and putting it back is the same " <>
         "one-column write — but the work minted to hold it would be orphaned rather than " <>
         "removed, and any placement, listing or price made against the new work after the " <>
         "split would have to be moved by hand"}

  @impl true
  def cast_argument(params) when is_map(params) do
    edition_id = params |> Map.get("edition_id") |> to_string() |> String.trim()
    title = params |> Map.get("title") |> to_string() |> String.trim()

    cond do
      Ecto.UUID.cast(edition_id) == :error -> {:error, :edition_id_required}
      title == "" -> {:error, :title_required}
      true -> {:ok, %{edition_id: edition_id, title: title}}
    end
  end

  def cast_argument(_), do: {:error, :argument_required}

  @impl true
  def plan(%{edition_id: edition_id, title: title}) do
    with {:ok, edition} <- fetch_edition(edition_id),
         :ok <- refuse_primary(edition),
         {:ok, work} <- refuse_last_edition(edition) do
      {:ok, [change(edition, work, title)]}
    end
  end

  @impl true
  def apply_change(%{id: edition_id, from: %{work_id: work_id}, to: to}) do
    with {:ok, work} <- mint_work(to),
         :ok <- Column.swap(@work, edition_id, uuid(work_id), uuid(work.id)),
         :ok <- Column.swap(@primary, edition_id, false, true) do
      {moved, _} =
        Repo.update_all(
          from(p in Placement, where: p.book_edition_id == ^edition_id),
          set: [book_id: work.id, updated_at: DateTime.utc_now()]
        )

      BookDetailCache.invalidate(work_id)
      BookDetailCache.invalidate(work.id)

      {:ok, %{new_work_id: work.id, placements_moved: moved}}
    end
  end

  defp fetch_edition(edition_id) do
    case Repo.get(BookEdition, edition_id) do
      nil -> {:error, {:unknown_edition, edition_id}}
      edition -> {:ok, edition}
    end
  end

  defp refuse_primary(%BookEdition{is_primary: true, id: id}),
    do: {:error, {:primary_edition, id}}

  defp refuse_primary(%BookEdition{}), do: :ok

  defp refuse_last_edition(edition) do
    siblings =
      Repo.aggregate(from(e in BookEdition, where: e.book_id == ^edition.book_id), :count)

    if siblings > 1 do
      {:ok, Repo.get!(Book, edition.book_id)}
    else
      {:error, {:only_edition_of_work, edition.id}}
    end
  end

  defp change(edition, work, title) do
    movers =
      Repo.aggregate(from(p in Placement, where: p.book_edition_id == ^edition.id), :count)

    retained =
      Repo.aggregate(
        from(p in Placement,
          where: p.book_id == ^work.id,
          where: p.book_edition_id != ^edition.id or is_nil(p.book_edition_id)
        ),
        :count
      )

    %{
      id: edition.id,
      from: %{work_id: work.id, work_title: work.title},
      to: %{work_title: title, visibility_tier: work.visibility_tier},
      because:
        "ISBN #{edition.isbn} is not an edition of #{inspect(work.title)}; splitting it onto " <>
          "its own work. #{movers} placement(s) name this edition and follow it (#396 — the " <>
          "recorded scan is the evidence); #{retained} placement(s) stay on " <>
          "#{inspect(work.title)}, whose readers' acquisitions are not recorded and may not " <>
          "be guessed."
    }
  end

  defp mint_work(%{work_title: title, visibility_tier: visibility_tier}) do
    %Book{}
    |> Books.book_changeset(%{"title" => title, "visibility_tier" => visibility_tier})
    |> Repo.insert()
    |> case do
      {:ok, work} -> {:ok, work}
      {:error, changeset} -> {:error, {:could_not_mint_work, changeset}}
    end
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)
end
