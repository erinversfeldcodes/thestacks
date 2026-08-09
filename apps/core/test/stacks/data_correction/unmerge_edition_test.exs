defmodule Stacks.DataCorrection.UnmergeEditionTest do
  @moduledoc """
  Issue #376 — the inverse of `Stacks.Books.merge_edition/2`, and the
  parameterised sibling to `Stacks.DataCorrection.run/2` that #340 said it would
  need.

  The centrepiece is `describe "placements"`. #376's hard question is not the row
  split, it is what happens to the readers, and the answer here is *nothing* —
  so the assertion has to be one that fails if the code moves them, not one that
  passes whatever happens. Both directions are asserted: the placements on the
  work that keeps its identity are still there, and the new work has none.

  `describe "a correction that cannot be recorded"` is copied from #340's test
  of the same name, deliberately: the targeted path must share that guarantee
  rather than reimplement it, and the way to show it shares it is to show it
  fails the same way — `{:error, {row_id, cause}}`, a shape only an
  audit-in-the-same-transaction can produce.
  """
  use Core.DataCase, async: false

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Books
  alias Stacks.Books.Book
  alias Stacks.Books.BookEdition
  alias Stacks.DataCorrection
  alias Stacks.DataCorrection.UnmergeEdition
  alias Stacks.Shelving.Placement

  @new_title "Dune Messiah"

  # A work carrying a wrongly merged edition, plus two readers who put the work
  # on a shelf. `merge_edition/2` inserts every merged edition with
  # `is_primary: false`, which is the whole reason no placement can ever name
  # one — so the fixture builds that shape rather than a convenient one.
  defp wrongly_merged(work_attrs \\ []) do
    work = insert(:book, work_attrs)
    [primary] = work.editions
    merged = Repo.insert!(build(:book_edition, book: work, is_primary: false))

    readers = for _ <- 1..2, do: insert(:placement, book: work)

    %{work: work, primary: primary, merged: merged, readers: readers}
  end

  defp argument(edition_id, title \\ @new_title),
    do: %{edition_id: edition_id, title: title}

  defp work_id_of(edition_id),
    do: Repo.one(from(e in BookEdition, where: e.id == ^edition_id, select: e.book_id))

  defp primary?(edition_id),
    do: Repo.one(from(e in BookEdition, where: e.id == ^edition_id, select: e.is_primary))

  defp placement_work_ids,
    do: Repo.all(from(p in Placement, select: p.book_id, order_by: p.id))

  defp audit_rows do
    %{rows: rows} =
      Repo.query!(
        "SELECT resource_id, user_id, metadata FROM audit.audit_log WHERE action = 'data.correction.applied'"
      )

    Enum.map(rows, fn [resource_id, user_id, metadata] ->
      {:ok, json} = Stacks.Vault.decrypt(metadata)
      {Ecto.UUID.load!(resource_id), user_id && Ecto.UUID.load!(user_id), Jason.decode!(json)}
    end)
  end

  # ── Casting the operator's argument ───────────────────────────────────────

  describe "cast_argument/1" do
    test "accepts the two keys it documents and nothing else" do
      id = Ecto.UUID.generate()

      assert {:ok, %{edition_id: ^id, title: @new_title}} =
               UnmergeEdition.cast_argument(%{
                 "edition_id" => id,
                 "title" => @new_title,
                 "book_id" => Ecto.UUID.generate(),
                 "visibility_tier" => "public"
               })
    end

    test "refuses an edition_id that is not a uuid" do
      assert {:error, :edition_id_required} =
               UnmergeEdition.cast_argument(%{"edition_id" => "../../etc", "title" => "x"})
    end

    test "refuses a blank title — the operator states what the book actually is" do
      id = Ecto.UUID.generate()

      assert {:error, :title_required} =
               UnmergeEdition.cast_argument(%{"edition_id" => id, "title" => "   "})

      assert {:error, :title_required} = UnmergeEdition.cast_argument(%{"edition_id" => id})
    end
  end

  # ── Planning refuses what it should not touch ─────────────────────────────

  describe "planning" do
    test "refuses an edition that does not exist" do
      id = Ecto.UUID.generate()

      assert {:error, {:unknown_edition, ^id}} =
               DataCorrection.run_targeted(UnmergeEdition, argument(id))
    end

    test "refuses a work's primary edition" do
      %{primary: primary} = wrongly_merged()

      assert {:error, {:primary_edition, _}} =
               DataCorrection.run_targeted(UnmergeEdition, argument(primary.id))
    end

    test "refuses the only edition of a work — the work must keep one" do
      # Deliberately an `:editionless_book` plus one NON-primary edition. A
      # `:book` factory work's sole edition is its primary, so it would be
      # refused by the guard above and this one would never run.
      work = insert(:editionless_book)
      only = Repo.insert!(build(:book_edition, book: work, is_primary: false))

      assert {:error, {:only_edition_of_work, _}} =
               DataCorrection.run_targeted(UnmergeEdition, argument(only.id))
    end

    test "reports the destination, the work being left, and the placements that stay" do
      %{work: work, merged: merged} = wrongly_merged()

      assert {:ok, outcome} = DataCorrection.run_targeted(UnmergeEdition, argument(merged.id))

      assert outcome.mode == :dry_run
      assert outcome.count == 1
      assert outcome.scope =~ merged.id
      assert {:reversible, _} = outcome.reversibility

      work_id = work.id
      work_title = work.title

      assert [
               %{
                 id: _,
                 from: %{work_id: ^work_id, work_title: ^work_title},
                 to: %{work_title: @new_title},
                 because: because
               }
             ] = outcome.changes

      # The blast radius the operator needs before deciding: how many readers
      # are left holding the work this edition is leaving.
      assert because =~ "2 placement(s) stay on"
      assert because =~ merged.isbn
    end

    test "a dry run writes nothing" do
      %{work: work, merged: merged} = wrongly_merged()

      assert {:ok, _} = DataCorrection.run_targeted(UnmergeEdition, argument(merged.id))

      assert work_id_of(merged.id) == work.id
      assert Repo.aggregate(Book, :count) == 1
      assert audit_rows() == []
    end
  end

  # ── The split itself ──────────────────────────────────────────────────────

  describe "applying" do
    setup do
      {:ok, wrongly_merged()}
    end

    test "moves the edition onto a work of its own", ctx do
      assert {:ok, outcome} =
               DataCorrection.run_targeted(UnmergeEdition, argument(ctx.merged.id),
                 apply: true,
                 invoked_by: "test"
               )

      assert outcome.mode == :applied
      assert outcome.count == 1

      new_work_id = work_id_of(ctx.merged.id)
      refute new_work_id == ctx.work.id
      assert Repo.get!(Book, new_work_id).title == @new_title

      # The work it left keeps its own identity and its own edition.
      assert work_id_of(ctx.primary.id) == ctx.work.id
      assert Repo.get!(Book, ctx.work.id).title == ctx.work.title
    end

    test "makes the split-out edition the primary of its new work", ctx do
      refute primary?(ctx.merged.id)

      DataCorrection.run_targeted(UnmergeEdition, argument(ctx.merged.id),
        apply: true,
        invoked_by: "test"
      )

      assert primary?(ctx.merged.id)
      # And the work it left still has exactly one primary — its own.
      assert primary?(ctx.primary.id)
    end

    test "the ISBN now resolves to the new work, which is the repair", ctx do
      assert Books.find_existing(ctx.merged.isbn).id == ctx.work.id

      DataCorrection.run_targeted(UnmergeEdition, argument(ctx.merged.id),
        apply: true,
        invoked_by: "test"
      )

      resolved = Books.find_existing(ctx.merged.isbn)

      refute resolved.id == ctx.work.id
      assert resolved.title == @new_title
    end

    # Idempotence is not claimed for a targeted correction (see
    # `Stacks.DataCorrection.Targeted`), so what has to hold is that a second
    # run refuses rather than compounds. It refuses at the *first* guard: the
    # split promoted the edition to its new work's primary, and a primary
    # edition is never a merged one. A second work is not minted either.
    test "refuses a second run — the edition is now its own work's primary", ctx do
      opts = [apply: true, invoked_by: "test"]

      assert {:ok, _} = DataCorrection.run_targeted(UnmergeEdition, argument(ctx.merged.id), opts)

      after_first = work_id_of(ctx.merged.id)
      merged_id = ctx.merged.id

      assert {:error, {:primary_edition, ^merged_id}} =
               DataCorrection.run_targeted(UnmergeEdition, argument(ctx.merged.id), opts)

      assert work_id_of(ctx.merged.id) == after_first
      assert Repo.aggregate(Book, :count) == 2
    end
  end

  # ── The age gate may not be widened by a repair ───────────────────────────

  describe "visibility" do
    test "the new work inherits the age gate rather than defaulting to public" do
      %{merged: merged} = wrongly_merged(visibility_tier: "age_gated")

      DataCorrection.run_targeted(UnmergeEdition, argument(merged.id),
        apply: true,
        invoked_by: "test"
      )

      assert Repo.get!(Book, work_id_of(merged.id)).visibility_tier == "age_gated"
    end
  end

  # ── The disposition decision ──────────────────────────────────────────────

  # #376's actual hard question. The decision is that placements stay, because
  # no placement has ever named a merged edition — `Shelving.place_book/3`
  # writes the work's PRIMARY edition and `merge_edition/2` never creates a
  # primary — so which readers acquired the split-out edition is not recorded
  # and cannot be derived.
  #
  # Asserted in both directions on purpose: "the old work still has both" alone
  # would pass if the code copied placements, and "the new work has none" alone
  # would pass if the code deleted them.
  describe "placements" do
    setup do
      {:ok, wrongly_merged()}
    end

    test "stay on the work they were made against", ctx do
      before = placement_work_ids()
      assert before == [ctx.work.id, ctx.work.id]

      DataCorrection.run_targeted(UnmergeEdition, argument(ctx.merged.id),
        apply: true,
        invoked_by: "test"
      )

      new_work_id = work_id_of(ctx.merged.id)

      assert placement_work_ids() == before
      assert Repo.aggregate(from(p in Placement, where: p.book_id == ^ctx.work.id), :count) == 2
      assert Repo.aggregate(from(p in Placement, where: p.book_id == ^new_work_id), :count) == 0
    end

    test "keep the edition they were pointed at, which was never the merged one", ctx do
      DataCorrection.run_targeted(UnmergeEdition, argument(ctx.merged.id),
        apply: true,
        invoked_by: "test"
      )

      edition_ids =
        Repo.all(from(p in Placement, select: p.book_edition_id)) |> Enum.uniq()

      assert edition_ids == [ctx.primary.id]
      refute ctx.merged.id in edition_ids
    end

    # #396 — the post-#378 case: place_book/4 records the SCANNED edition, so a
    # placement can name the edition being split. That row is evidence, not a
    # guess: the reader's copy IS the split-out book, and the placement follows
    # it — or the reparent would leave book_id and book_edition_id naming
    # different works.
    test "a placement naming the split edition follows it to the new work (#396)", ctx do
      scanner = insert(:placement, book: ctx.work, book_edition_id: ctx.merged.id)

      DataCorrection.run_targeted(UnmergeEdition, argument(ctx.merged.id),
        apply: true,
        invoked_by: "test"
      )

      new_work_id = work_id_of(ctx.merged.id)
      moved = Repo.reload!(scanner)

      # Internally consistent: both FKs on the SAME (new) work…
      assert moved.book_id == new_work_id
      assert moved.book_edition_id == ctx.merged.id

      # …while the two primary-edition readers stay put, untouched.
      assert Repo.aggregate(from(p in Placement, where: p.book_id == ^ctx.work.id), :count) == 2
    end

    test "the plan states both counts — who follows the edition, who stays (#396)", ctx do
      insert(:placement, book: ctx.work, book_edition_id: ctx.merged.id)

      {:ok, [change]} = UnmergeEdition.plan(argument(ctx.merged.id))

      assert change.because =~ "1 placement(s) name this edition and follow it"
      assert change.because =~ "2 placement(s) stay on"
    end
  end

  # ── The audit ─────────────────────────────────────────────────────────────

  describe "the audit row" do
    setup do
      {:ok, wrongly_merged()}
    end

    test "records the actor, the reason, and where the row actually went", ctx do
      actor = insert(:owner_user)

      DataCorrection.run_targeted(UnmergeEdition, argument(ctx.merged.id),
        apply: true,
        invoked_by: "admin api",
        actor_id: actor.id,
        reason: "reader reported this ISBN is a different novel entirely"
      )

      merged_id = ctx.merged.id
      actor_id = actor.id

      assert [{^merged_id, ^actor_id, metadata}] = audit_rows()

      assert metadata["correction"] == "unmerge_edition"
      assert metadata["invoked_by"] == "admin api"
      assert metadata["reason"] =~ "a different novel entirely"
      assert metadata["reversibility"] =~ "reversible"
      assert metadata["scope"] =~ merged_id
      assert metadata["from"]["work_id"] == ctx.work.id
      assert metadata["to"]["work_title"] == @new_title

      # The destination did not exist when the plan was made, so only the
      # applied run can say where the edition went. Without it the trail names
      # a row that cannot be found.
      assert metadata["new_work_id"] == work_id_of(ctx.merged.id)
    end

    test "a correction may not overwrite the fields the mechanism controls", ctx do
      DataCorrection.run_targeted(UnmergeEdition, argument(ctx.merged.id),
        apply: true,
        invoked_by: "test"
      )

      assert [{_, nil, metadata}] = audit_rows()
      assert metadata["correction"] == "unmerge_edition"
    end
  end

  # ── The audit shares the change's transaction ─────────────────────────────

  # Copied from #340's test of the same name. The targeted path must inherit
  # that guarantee rather than reimplement it, and the proof is that it fails
  # identically: `{:error, {the row's id, the audit's own error}}`. A
  # best-effort audit — one that logs and carries on — cannot produce that
  # shape, and neither can a second audit path that only looks like the first.
  describe "a correction that cannot be recorded" do
    setup do
      {:ok, wrongly_merged()}
    end

    test "does not happen", ctx do
      Repo.query!("ALTER TABLE audit.audit_log RENAME TO audit_log_absent")

      result =
        DataCorrection.run_targeted(UnmergeEdition, argument(ctx.merged.id),
          apply: true,
          invoked_by: "test"
        )

      Repo.query!("ALTER TABLE audit.audit_log_absent RENAME TO audit_log")

      id = ctx.merged.id

      assert {:error, {^id, %Postgrex.Error{postgres: %{code: :undefined_table}}}} = result

      # Not the edition's move, and not the work minted to receive it.
      assert work_id_of(ctx.merged.id) == ctx.work.id
      refute primary?(ctx.merged.id)
      assert Repo.aggregate(Book, :count) == 1
      assert audit_rows() == []
    end
  end
end
