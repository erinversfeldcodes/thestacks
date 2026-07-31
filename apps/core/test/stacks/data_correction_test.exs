defmodule Stacks.DataCorrectionTest do
  @moduledoc """
  Issue #339 — the ISBN repair, and the mechanism it is the first instance of.

  The centrepiece is `describe "the deploy that #339 aborted"`: it drops the real
  CHECK constraint, plants the two ISBN-10s production actually holds, shows that
  re-adding the constraint fails exactly as the deploy did, runs the correction,
  and shows the same statement now succeeds. The constraint definition is read
  back out of `pg_constraint` rather than re-spelled, so the test validates
  against the production expression verbatim and cannot drift from it.
  """
  use Core.DataCase, async: false

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Books.BookEdition
  alias Stacks.Books.ISBN
  alias Stacks.DataCorrection
  alias Stacks.DataCorrection.NormaliseEditionIsbn10
  alias Stacks.DataCorrection.StaleSeedEditionIsbn

  @constraint "book_editions_isbn_ean13_checksum"

  # The two rows the Wave 4 live drive found in production
  # (`square-art-39019825`), verbatim.
  @prod_isbn10s [
    {"0071615695", "9780071615693", "Schaum's Outline of Complex Variables, 2ed"},
    {"0062028510", "9780062028518", "The Fury"}
  ]

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp constraint_definition do
    %{rows: [[definition]]} =
      Repo.query!("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1", [
        @constraint
      ])

    definition
  end

  defp drop_constraint! do
    Repo.query!("ALTER TABLE op.book_editions DROP CONSTRAINT #{@constraint}")
  end

  # Re-adding validates against every existing row, which is precisely what
  # `20260730200350`'s VALIDATE does.
  defp add_constraint!(definition) do
    Repo.query!("ALTER TABLE op.book_editions ADD CONSTRAINT #{@constraint} #{definition}")
  end

  # Writes a row the current constraint forbids, the way a pre-2026-05-15
  # write path did: no changeset, no normalisation.
  defp plant_legacy_edition!(isbn, id \\ nil) do
    # `insert(:book)` builds its primary edition too (#329), and a work may hold
    # only one primary — so the legacy row needs a work of its own.
    book = insert(:editionless_book)
    id = id || Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO op.book_editions
        (id, book_id, isbn, is_primary, verification_source, created_at, updated_at)
      VALUES ($1, $2, $3, true, 'barcode_unverified', now(), now())
      """,
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(book.id), isbn]
    )

    id
  end

  defp isbn_of(id) do
    Repo.one(from e in BookEdition, where: e.id == ^id, select: e.isbn)
  end

  defp audit_rows do
    %{rows: rows} =
      Repo.query!(
        "SELECT resource_id, metadata FROM audit.audit_log WHERE action = 'data.correction.applied'"
      )

    Enum.map(rows, fn [resource_id, metadata] ->
      {:ok, json} = Stacks.Vault.decrypt(metadata)
      {Ecto.UUID.load!(resource_id), Jason.decode!(json)}
    end)
  end

  # ── The conversion itself ─────────────────────────────────────────────────

  describe "ISBN-10 to ISBN-13 conversion, against the real production values" do
    test "both production ISBN-10s convert to the expected ISBN-13" do
      for {isbn10, isbn13, _title} <- @prod_isbn10s do
        assert ISBN.canonical_isbn13(isbn10) == isbn13
      end
    end

    test "both production ISBN-10s are genuinely valid ISBN-10s" do
      for {isbn10, _isbn13, _title} <- @prod_isbn10s do
        assert ISBN.valid_isbn_checksum?(isbn10),
               "#{isbn10} must be a valid ISBN-10 — the conversion is only sound if it is"
      end
    end

    test "the converted values pass the checksum the CHECK constraint enforces" do
      for {_isbn10, isbn13, _title} <- @prod_isbn10s do
        assert ISBN.valid_isbn_checksum?(isbn13)
        assert String.length(isbn13) == 13
      end
    end

    test "the converted values are accepted by the live CHECK constraint" do
      for {_isbn10, isbn13, title} <- @prod_isbn10s do
        book = insert(:book, title: title)
        assert {:ok, %BookEdition{}} = Repo.insert(build(:book_edition, book: book, isbn: isbn13))
      end
    end

    test "a ten-digit string with a bad check digit is not claimed as convertible" do
      # 0071615690 — same nine digits, wrong check digit.
      refute ISBN.valid_isbn_checksum?("0071615690")
    end
  end

  # ── The acceptance test: the deploy failure, and its fix ──────────────────

  describe "the deploy that #339 aborted" do
    setup do
      definition = constraint_definition()
      drop_constraint!()

      ids =
        Map.new(@prod_isbn10s, fn {isbn10, _isbn13, _title} ->
          {isbn10, plant_legacy_edition!(isbn10)}
        end)

      %{definition: definition, ids: ids}
    end

    test "before the correction, validating the constraint fails on those rows", ctx do
      # Nested in its own transaction so the check_violation rolls back to a
      # savepoint and leaves the test's sandbox transaction usable.
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.transaction(fn ->
                 case Repo.query(
                        "ALTER TABLE op.book_editions ADD CONSTRAINT #{@constraint} #{ctx.definition}"
                      ) do
                   {:ok, result} -> result
                   {:error, error} -> Repo.rollback(error)
                 end
               end)
    end

    test "after the correction, the same statement succeeds", ctx do
      assert {:ok, %{mode: :applied, count: 2}} =
               DataCorrection.run(NormaliseEditionIsbn10, apply: true, invoked_by: "test")

      add_constraint!(ctx.definition)

      for {isbn10, isbn13, _title} <- @prod_isbn10s do
        assert isbn_of(ctx.ids[isbn10]) == isbn13
      end
    end
  end

  # ── The mechanism's guarantees ────────────────────────────────────────────

  describe "dry-run is the default" do
    setup do
      definition = constraint_definition()
      drop_constraint!()
      id = plant_legacy_edition!("0071615695")
      %{definition: definition, id: id}
    end

    test "run/2 with no options changes nothing", ctx do
      assert {:ok, outcome} = DataCorrection.run(NormaliseEditionIsbn10)

      assert outcome.mode == :dry_run
      assert outcome.count == 1
      assert [%{from: "0071615695", to: "9780071615693"}] = outcome.changes

      assert isbn_of(ctx.id) == "0071615695"
      assert audit_rows() == []
    end

    test "the dry-run report names the row, both values and the scope" do
      {:ok, outcome} = DataCorrection.run(NormaliseEditionIsbn10)

      assert outcome.report =~ "normalise_edition_isbn10 (dry_run)"
      assert outcome.report =~ "0071615695"
      assert outcome.report =~ "9780071615693"
      assert outcome.report =~ "10 digits with a valid ISBN-10 check digit"
      assert outcome.report =~ "DRY RUN — nothing was written"
    end
  end

  describe "applying" do
    setup do
      definition = constraint_definition()
      drop_constraint!()
      ids = Enum.map(["0071615695", "0062028510"], &{&1, plant_legacy_edition!(&1)})
      %{definition: definition, ids: Map.new(ids)}
    end

    test "is idempotent — the second run is a no-op", ctx do
      assert {:ok, %{count: 2, mode: :applied}} =
               DataCorrection.run(NormaliseEditionIsbn10, apply: true, invoked_by: "test")

      first_pass_audit = length(audit_rows())
      assert first_pass_audit == 2

      assert NormaliseEditionIsbn10.plan() == []

      assert {:ok, %{count: 0, mode: :applied}} =
               DataCorrection.run(NormaliseEditionIsbn10, apply: true, invoked_by: "test")

      assert length(audit_rows()) == first_pass_audit
      assert isbn_of(ctx.ids["0071615695"]) == "9780071615693"
    end

    test "records what changed, from what, to what, why and who", ctx do
      DataCorrection.run(NormaliseEditionIsbn10, apply: true, invoked_by: "the test")

      rows = Map.new(audit_rows())
      entry = rows[ctx.ids["0062028510"]]

      assert entry["correction"] == "normalise_edition_isbn10"
      assert entry["from"] == "0062028510"
      assert entry["to"] == "9780062028518"
      assert entry["because"] =~ "unnormalised"
      assert entry["invoked_by"] == "the test"
      assert entry["scope"] =~ "10 digits"
    end

    test "refuses a change that would collide with an existing edition", ctx do
      # A second edition already owns the ISBN-13 the repair would produce.
      book = insert(:book)
      Repo.insert!(build(:book_edition, book: book, isbn: "9780071615693"))

      assert {:error, {id, {:isbn_already_present, "9780071615693"}}} =
               DataCorrection.run(NormaliseEditionIsbn10, apply: true, invoked_by: "test")

      assert id == ctx.ids["0071615695"]

      # Nothing was committed — including the other row's correction.
      assert isbn_of(ctx.ids["0071615695"]) == "0071615695"
      assert isbn_of(ctx.ids["0062028510"]) == "0062028510"
      assert audit_rows() == []
    end

    test "leaves a ten-digit string that is not an ISBN-10 alone", ctx do
      bad = plant_legacy_edition!("0071615690")

      {:ok, outcome} = DataCorrection.run(NormaliseEditionIsbn10, apply: true, invoked_by: "test")

      assert outcome.count == 2
      assert isbn_of(bad) == "0071615690"
      refute is_nil(ctx.ids["0071615695"])
    end
  end

  # ── The unrepairable rows ─────────────────────────────────────────────────

  describe "stale seed editions" do
    setup do
      definition = constraint_definition()
      drop_constraint!()

      for {id, from, _to} <- StaleSeedEditionIsbn.fixtures(), do: plant_legacy_edition!(from, id)

      %{definition: definition}
    end

    test "the three fixtures are re-synced to the value seeds.exs now declares", ctx do
      assert {:ok, %{count: 3, mode: :applied}} =
               DataCorrection.run(StaleSeedEditionIsbn, apply: true, invoked_by: "test")

      for {id, _from, to} <- StaleSeedEditionIsbn.fixtures() do
        assert isbn_of(id) == to
      end

      add_constraint!(ctx.definition)
    end

    test "nothing is deleted — every fixture row survives the correction" do
      before = Repo.aggregate(BookEdition, :count)

      DataCorrection.run(StaleSeedEditionIsbn, apply: true, invoked_by: "test")

      assert Repo.aggregate(BookEdition, :count) == before
    end

    test "a fixture id holding some other value is out of scope" do
      {id, _from, _to} = hd(StaleSeedEditionIsbn.fixtures())

      Repo.query!("UPDATE op.book_editions SET isbn = '9780141036144' WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

      plan = StaleSeedEditionIsbn.plan()

      assert length(plan) == 2
      refute Enum.any?(plan, &(&1.id == id))
    end

    test "is idempotent" do
      DataCorrection.run(StaleSeedEditionIsbn, apply: true, invoked_by: "test")

      assert StaleSeedEditionIsbn.plan() == []
      assert {:ok, %{count: 0}} = DataCorrection.run(StaleSeedEditionIsbn, apply: true)
    end
  end

  describe "a database that has not been migrated yet" do
    # Corrections run BEFORE migrations, so bringing up a fresh environment
    # calls them against a database with no tables. Renaming (not dropping) the
    # table is the cheapest way to reach that state; the sandbox transaction
    # puts it back.
    setup do
      Repo.query!("ALTER TABLE op.book_editions RENAME TO book_editions_absent")
      :ok
    end

    test "every correction plans nothing rather than raising" do
      assert {:ok, outcomes} = DataCorrection.run_all(DataCorrection.Registry.all())
      assert Enum.all?(outcomes, &(&1.count == 0))
    end

    test "applying is a no-op too" do
      assert {:ok, outcomes} =
               DataCorrection.run_all(DataCorrection.Registry.all(),
                 apply: true,
                 invoked_by: "test"
               )

      assert Enum.all?(outcomes, &(&1.count == 0))
      assert audit_rows() == []
    end
  end

  describe "run_all/2" do
    test "runs every registered correction and is a no-op on clean data" do
      assert {:ok, outcomes} = DataCorrection.run_all(DataCorrection.Registry.all())

      assert Enum.map(outcomes, & &1.correction) == [
               "normalise_edition_isbn10",
               "stale_seed_edition_isbn"
             ]

      assert Enum.all?(outcomes, &(&1.count == 0))
      assert Enum.all?(outcomes, &(&1.mode == :dry_run))
    end
  end
end
