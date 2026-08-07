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

  ## Placements stay on the work they were made against

  This is the disposition decision #376 asks for, and the evidence is that the
  database does not record what the other choice would need.

  This held categorically *before #378*: `Stacks.Shelving.place_book/3` always
  wrote the work's *primary* edition (`primary_edition_id/1` orders
  `desc: is_primary`), `do_reread_book/2` carried an existing value forward, and
  `merge_edition/2` inserts every merged edition with `is_primary: false` — so no
  placement ever named a merged edition, and there was no row-level evidence of
  who acquired the edition being split out.

  ⚠️ **#378 weakens that premise.** `place_book/4` now records the *scanned*
  edition, so a placement created after #378 CAN name a non-primary (and thus a
  later-merged) edition. Un-merge still does not move placements here, but the
  justification is no longer "it is impossible"; it is "the owner-only correction
  path does not yet reconcile a placement that names the split edition." Handling
  that case — re-point such a placement to the surviving work, or move it — is
  tracked as its own follow-up (#396); until then a placement whose
  `book_edition_id` is the edition being split will keep pointing at it across the
  reparent, leaving `book_id`/`book_edition_id` on different works.

  Moving placements would therefore be guessing, and every available rule guesses
  badly: "move them all" relocates readers who own the original book and never
  touched this ISBN; "move the ones created after the merge" catches everyone who
  added the original in that window; "move the ones whose upload named the ISBN"
  reads evidence that GDPR image retention deletes after 30 days and that the
  manual-ISBN path never writes at all. A wrong reassignment is a second wrong
  merge, performed on user data, and it is not undoable by the same argument that
  makes the merge itself not undoable.

  So they stay, and the correction is not thereby cosmetic. The repair that
  matters is at the source: after the split the ISBN resolves to the right work
  for every future lookup, the wrong work stops advertising a book it does not
  contain, and the split-out book exists as itself. What is left is a bounded,
  countable set of readers whose shelf shows the old work — and the plan states
  that count in its `:because`, before anything is written, so the operator sees
  the blast radius and can reach those readers as a human decision rather than
  having one made for them silently.

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
        "plus one new op.books row to hold it. No placement is touched."

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
      # The book detail page is served from a 5-minute ETS cache keyed by work
      # id, so without this both works keep describing the pre-split shape for
      # up to five minutes — the same eviction-under-the-wrong-key defect #355
      # found. Evicted in-band rather than by event, because the operator reads
      # the result back immediately and Oban dispatch is asynchronous.
      BookDetailCache.invalidate(work_id)
      BookDetailCache.invalidate(work.id)

      {:ok, %{new_work_id: work.id}}
    end
  end

  # ── Planning ──────────────────────────────────────────────────────────────

  defp fetch_edition(edition_id) do
    case Repo.get(BookEdition, edition_id) do
      nil -> {:error, {:unknown_edition, edition_id}}
      edition -> {:ok, edition}
    end
  end

  # A merged edition is always `is_primary: false` (`Books.merge_edition/2`
  # hardcodes it), so a primary edition was never merged and splitting it would
  # take the work's representative row away from it.
  defp refuse_primary(%BookEdition{is_primary: true, id: id}),
    do: {:error, {:primary_edition, id}}

  defp refuse_primary(%BookEdition{}), do: :ok

  # The work must keep an edition. A work with none is not reachable by ISBN and
  # not describable on a detail page, and "split the only edition out" is a
  # rename asking to be a repair.
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
    retained = Repo.aggregate(from(p in Placement, where: p.book_id == ^work.id), :count)

    %{
      id: edition.id,
      from: %{work_id: work.id, work_title: work.title},
      to: %{work_title: title, visibility_tier: work.visibility_tier},
      because:
        "ISBN #{edition.isbn} is not an edition of #{inspect(work.title)}; splitting it onto " <>
          "its own work. #{retained} placement(s) stay on #{inspect(work.title)} — no " <>
          "placement has ever named a merged edition, so which readers acquired this one is " <>
          "not recorded and may not be guessed."
    }
  end

  # ── Applying ──────────────────────────────────────────────────────────────

  defp mint_work(%{work_title: title, visibility_tier: visibility_tier}) do
    %Book{}
    |> Books.book_changeset(%{"title" => title, "visibility_tier" => visibility_tier})
    |> Repo.insert()
    |> case do
      {:ok, work} -> {:ok, work}
      {:error, changeset} -> {:error, {:could_not_mint_work, changeset}}
    end
  end

  # `Column.swap/4` dumps the row id but hands `from`/`to` to Postgrex as it
  # received them, and `book_id` is a `uuid` column — so the caller dumps.
  defp uuid(id), do: Ecto.UUID.dump!(id)
end
