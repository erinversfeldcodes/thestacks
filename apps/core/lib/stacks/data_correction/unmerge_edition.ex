defmodule Stacks.DataCorrection.UnmergeEdition do
  @moduledoc """
  Splits a wrongly merged edition back off the work it was merged into (#376).

  `Stacks.Books.merge_edition/2` is a one-way door: it writes a second
  `op.book_editions` row under an existing work, and nothing takes it back. When
  the merge was wrong — the ISBN names a genuinely different book, not another
  format of the same one — the work permanently claims a book it is not, the
  ISBN permanently resolves to the wrong title for every reader who scans it
  (`Stacks.Books.find_existing/1` looks the edition up and returns its *parent*),
  and the only recourse was a `psql` session. The owner's 2026-07-30 ruling was
  that this is an owner-side data correction, not public UI.

  ## What it changes, and what it does not

  Exactly two columns of exactly one row:

    * `op.book_editions.book_id` — from the work the edition was merged into, to
      a newly minted work that holds only this edition.
    * `op.book_editions.is_primary` — to `true`. The split-out edition is the
      only edition of its new work, and a work whose sole edition is
      non-primary is a shape nothing else in the system produces.
      `op.book_editions_one_primary_per_book` accepts it because the new work
      has no other edition to conflict with.

  The new work inherits **`visibility_tier`** from the work it leaves and
  nothing else. That single inheritance is a safety property, not a
  convenience: splitting an edition out of an `age_gated` work into a
  default-`public` one would silently un-gate content, and a repair may not
  widen an audience. Title is stated by the operator — the judgement that the
  merge was wrong *is* the judgement about what the book actually is. Author is
  left null rather than inherited, because inheriting it would assert something
  the split has just decided is false; `Stacks.Workers.EnrichBookJob` is the
  path that fills it in.

  Everything keyed on the **edition** follows it for free — prices
  (`op.price_history.book_edition_id`), partner inventory, uploaded images.
  Everything keyed on the **work** stays where it is, which includes
  `op.listings.book_id`. A listing for the split-out edition is left pointing at
  the old work; that is a live-listing decision for the operator and not
  something this correction should guess at.

  ## Placements: follow the recorded edition, and only the recorded edition

  This is the disposition decision #376 asked for, revised once by #396 when
  #378 changed what the database records. The rule has two halves, and each is
  driven by what a placement's `book_edition_id` actually says:

  **A placement that names the edition being split moves with it** — its
  `book_id` is rewritten to the newly minted work (#396). Post-#378,
  `Stacks.Shelving.place_book/4` records the *scanned* edition, so such a
  placement is row-level evidence that this reader's physical copy IS the
  split-out book. Moving it is not a guess; it is reading the record. The
  alternative (re-pointing it at the surviving work's primary edition) would
  assert the reader owns an edition they never scanned — a structurally valid
  but false row, the same class #378 itself repaired. It also keeps the row
  internally consistent: without the move, the reparent would leave `book_id`
  (old work) and `book_edition_id` (new work) naming different works. The new
  work is minted by this very correction, so the move cannot collide with an
  existing placement.

  **Every other placement stays on the work it was made against.** For rows
  that name the primary (or carry no edition), the pre-#378 argument still
  governs: the database does not record who acquired the split-out edition,
  and every rule for guessing guesses badly — "move them all" relocates
  readers who own the original book and never touched this ISBN; "move the
  ones created after the merge" catches everyone who added the original in
  that window. A wrong reassignment is a second wrong merge, performed on user
  data, and it is not undoable by the same argument that makes the merge
  itself not undoable.

  Both counts are stated in the plan's `:because`, before anything is written,
  so the operator sees the blast radius — who follows the edition, who stays —
  as part of the dry run.

  ## Reading through Ecto rather than `Column`

  `Stacks.DataCorrection.Column`'s moduledoc argues for raw SQL because a
  correction usually runs where reality and the schema disagree, and the
  changeset that normalises the bad value away is how a repair becomes a no-op.
  That argument does not apply to the *reads* here: the edition row is entirely
  valid, its wrongness is a relationship rather than a value, and no changeset
  can normalise a foreign key away. This correction also never runs from the
  pre-migration deploy path, so `Column`'s `to_regclass` guard has nothing to
  protect. The **writes** still go through `Column.swap/4`, for the property that
  matters: a row that moved between planning and applying is refused.
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
