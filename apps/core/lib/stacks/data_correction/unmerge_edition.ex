defmodule Stacks.DataCorrection.UnmergeEdition do
  @moduledoc """
      Splits a wrongly merged edition back off its work —
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
  alias Stacks.Scope
  alias Stacks.Shelving.Bookshelf
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
        "follow it to the new work; every other placement is untouched."

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
      moved = repoint_placements(edition_id, work.id)

      BookDetailCache.invalidate(work_id)
      BookDetailCache.invalidate(work.id)

      {:ok, %{new_work_id: work.id, placements_moved: moved}}
    end
  end

  # ⛔ Once per owner, inside that owner's scope — not one `update_all` across
  # everybody.
  #
  # These placements belong to whichever users hold the split edition, and the
  # row-level policies show a scoped connection only its own user's rows. A
  # single update would therefore re-point one user's placements and silently
  # leave every other user's naming an edition that no longer means what it
  # did — a correction that reports a count and half-does the job.
  #
  # ⛔ The `where` clause narrows to the owner AND the scope is set. Both, and
  # the first draft had only the second — it relied on the policy to confine
  # each pass, which makes the code correct ONLY where the policy is enforced.
  # A test caught it immediately: under the superuser the suite runs as, row-level
  # security is bypassed, so every pass updated every matching row and a
  # two-owner fixture reported four placements moved instead of two.
  #
  # ⚠️ The general lesson is worth more than the fix. Code whose correctness
  # depends on row-level security being active is wrong in development, wrong
  # in the test suite, and wrong for any superuser — and it fails there by
  # over-reaching, which is the direction that does damage. The policy is the
  # backstop; the query still has to be right on its own.
  defp repoint_placements(edition_id, new_book_id) do
    edition_id
    |> placement_owners()
    |> Enum.reduce(0, fn owner_id, moved ->
      Scope.with_user(owner_id, fn ->
        owned =
          from(bs in Bookshelf, where: bs.user_id == ^owner_id, select: bs.id)

        {count, _} =
          Repo.update_all(
            from(p in Placement,
              where: p.book_edition_id == ^edition_id,
              where: p.bookshelf_id in subquery(owned)
            ),
            set: [book_id: new_book_id, updated_at: DateTime.utc_now()]
          )

        moved + count
      end)
    end)
  end

  # The one fact the correction cannot learn for itself: whose rows these are.
  # Answered by a `SECURITY DEFINER` read owned by a role that cannot log in,
  # rather than by exempting this path from the policies.
  defp placement_owners(edition_id) do
    %{rows: rows} =
      Repo.query!("SELECT user_id FROM op.placement_owners_for_edition($1::uuid)", [edition_id])

    Enum.map(rows, fn [raw] -> Ecto.UUID.cast!(raw) end)
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
          "its own work. #{movers} placement(s) name this edition and follow it (the " <>
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
