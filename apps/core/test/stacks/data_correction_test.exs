defmodule Stacks.DataCorrectionTest.RelabelVerificationSource do
  @moduledoc """
  Exercises 340's mechanism through a correction over a NON-isbn column,
  defined here and deliberately unregistered — proving the machinery
  generalises past the one column 339 needed (shaped after 370's
  `verification_source` repair, whose real disposition decision is not a
  test's to make). Covers dry-run, apply, audit-in-transaction, and the
  moved-row refusal.
  """
  @behaviour Stacks.DataCorrection

  alias Stacks.DataCorrection.Column

  @target {"op.book_editions", "verification_source"}
  @from "barcode_unverified"
  @to "open_library"

  @doc "The `{table, column}` this correction writes. Exposed for tests."
  def target, do: @target

  @impl true
  def name, do: "test_relabel_verification_source"

  @impl true
  def resource_type, do: "book_edition"

  @impl true
  def scope, do: "op.book_editions rows whose verification_source is #{@from}"

  @impl true
  def reversibility,
    do:
      {:one_way,
       "a relabel asserts something about how the row was verified; the audit row " <>
         "keeps the previous claim, but reversing it would assert the opposite"}

  @impl true
  def plan do
    for {id, value} <- Column.holding(@target, @from) do
      %{id: id, from: value, to: @to, because: "stand-in for #370's disposition"}
    end
  end

  @impl true
  def apply_change(%{id: id, from: from, to: to}), do: Column.swap(@target, id, from, to)
end

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
  alias Stacks.DataCorrection.Column
  alias Stacks.DataCorrection.NormaliseEditionIsbn10
  alias Stacks.DataCorrection.Registry
  alias Stacks.DataCorrection.StaleSeedEditionIsbn
  alias Stacks.DataCorrectionTest.RelabelVerificationSource

  @constraint "book_editions_isbn_ean13_checksum"

  @prod_isbn10s [
    {"0071615695", "9780071615693", "Schaum's Outline of Complex Variables, 2ed"},
    {"0062028510", "9780062028518", "The Fury"}
  ]

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

  defp add_constraint!(definition) do
    Repo.query!("ALTER TABLE op.book_editions ADD CONSTRAINT #{@constraint} #{definition}")
  end

  defp plant_legacy_edition!(isbn, id \\ nil) do
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
      refute ISBN.valid_isbn_checksum?("0071615690")
    end
  end

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
      book = insert(:book)
      Repo.insert!(build(:book_edition, book: book, isbn: "9780071615693"))

      assert {:error, {id, {:isbn_already_present, "9780071615693"}}} =
               DataCorrection.run(NormaliseEditionIsbn10, apply: true, invoked_by: "test")

      assert id == ctx.ids["0071615695"]

      assert isbn_of(ctx.ids["0071615695"]) == "0071615695"
      assert isbn_of(ctx.ids["0062028510"]) == "0062028510"
      assert audit_rows() == []
    end

    test "records the actor and the operator's reason, not just the entry point", ctx do
      actor = insert(:owner_user)

      DataCorrection.run(NormaliseEditionIsbn10,
        apply: true,
        invoked_by: "admin api",
        actor_id: actor.id,
        reason: "reader reported the book could not be found by its barcode"
      )

      %{rows: rows} =
        Repo.query!(
          "SELECT user_id FROM audit.audit_log WHERE action = 'data.correction.applied' AND resource_id = $1",
          [Ecto.UUID.dump!(ctx.ids["0062028510"])]
        )

      assert [[user_id]] = rows
      assert Ecto.UUID.load!(user_id) == actor.id

      entry = Map.new(audit_rows())[ctx.ids["0062028510"]]
      assert entry["invoked_by"] == "admin api"
      assert entry["reason"] =~ "could not be found by its barcode"
      assert entry["reversibility"] =~ "reversible"
    end

    test "leaves a ten-digit string that is not an ISBN-10 alone", ctx do
      bad = plant_legacy_edition!("0071615690")

      {:ok, outcome} = DataCorrection.run(NormaliseEditionIsbn10, apply: true, invoked_by: "test")

      assert outcome.count == 2
      assert isbn_of(bad) == "0071615690"
      refute is_nil(ctx.ids["0071615695"])
    end
  end

  describe "a correction that cannot be recorded" do
    setup do
      definition = constraint_definition()
      drop_constraint!()
      %{definition: definition, id: plant_legacy_edition!("0071615695")}
    end

    test "does not happen", ctx do
      Repo.query!("ALTER TABLE audit.audit_log RENAME TO audit_log_absent")

      result = DataCorrection.run(NormaliseEditionIsbn10, apply: true, invoked_by: "test")

      Repo.query!("ALTER TABLE audit.audit_log_absent RENAME TO audit_log")

      id = ctx.id

      assert {:error, {^id, %Postgrex.Error{postgres: %{code: :undefined_table}}}} = result

      assert isbn_of(ctx.id) == "0071615695"
      assert audit_rows() == []
    end
  end

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
               "stale_seed_edition_isbn",
               "seed_edition_verification_source"
             ]

      assert Enum.all?(outcomes, &(&1.count == 0))
      assert Enum.all?(outcomes, &(&1.mode == :dry_run))
    end
  end

  describe "Registry.fetch/1" do
    test "resolves a registered correction by its name" do
      assert {:ok, NormaliseEditionIsbn10} = Registry.fetch("normalise_edition_isbn10")
      assert {:ok, StaleSeedEditionIsbn} = Registry.fetch("stale_seed_edition_isbn")
    end

    test "an unregistered name resolves to nothing rather than to a module" do
      assert :error = Registry.fetch("delete_everything")
      assert :error = Registry.fetch("Elixir.Stacks.DataCorrection.NormaliseEditionIsbn10")
      assert :error = Registry.fetch("")
    end
  end

  describe "every registered correction" do
    test "states whether it can be reversed, and what an undo could not restore" do
      for correction <- Registry.all() do
        assert {disposition, why} = correction.reversibility()
        assert disposition in [:one_way, :reversible]

        assert String.length(why) > 20,
               "#{correction.name()} must say what reversal would and would not restore"
      end
    end

    test "prints its reversibility in the report an operator reads before applying" do
      {:ok, outcomes} = DataCorrection.run_all(Registry.all())

      for outcome <- outcomes do
        assert outcome.report =~ ~r/(one-way|reversible):/
      end
    end
  end

  describe "Column" do
    @isbn_target {"op.book_editions", "isbn"}

    test "writes only when the row still holds the old value" do
      definition = constraint_definition()
      drop_constraint!()
      id = plant_legacy_edition!("0071615695")

      assert {:error, {:row_no_longer_matches, ^id, "something else"}} =
               Column.swap(@isbn_target, id, "something else", "9780071615693")

      assert isbn_of(id) == "0071615695"
      assert :ok = Column.swap(@isbn_target, id, "0071615695", "9780071615693")
      assert isbn_of(id) == "9780071615693"

      add_constraint!(definition)
    end

    test "a NULL old value is a value, not a missing one" do
      book = insert(:book)
      edition = Repo.insert!(build(:book_edition, book: book, publisher: nil))

      assert Enum.any?(Column.holding({"op.book_editions", "publisher"}, nil), fn {id, value} ->
               id == edition.id and is_nil(value)
             end)

      assert :ok = Column.swap({"op.book_editions", "publisher"}, edition.id, nil, "Vintage")
      assert Repo.reload!(edition).publisher == "Vintage"
    end

    test "a column the migrations have not added yet reads as nothing-to-correct" do
      assert Column.holding({"op.book_editions", "not_yet_migrated_column"}, "x") == []
    end

    test "holding/2 selects exactly the rows carrying one value" do
      book = insert(:book)
      target = Repo.insert!(build(:book_edition, book: book, verification_source: "open_library"))

      ids =
        {"op.book_editions", "verification_source"}
        |> Column.holding("open_library")
        |> Enum.map(&elem(&1, 0))

      assert target.id in ids

      refute Enum.any?(
               Column.holding({"op.book_editions", "verification_source"}, "no_such_source"),
               &(elem(&1, 0) == target.id)
             )
    end

    test "refuses an identifier that is not a plain snake_case name" do
      for bad <- [
            {"op.book_editions; DROP TABLE op.users", "isbn"},
            {"op.book_editions", "isbn = '' OR 1=1"},
            {"op.book_editions", "\"isbn\""},
            {"OP.BOOK_EDITIONS", "isbn"}
          ] do
        assert_raise ArgumentError, ~r/not a plain snake_case SQL identifier/, fn ->
          Column.matching(bad, "^x$")
        end

        assert_raise ArgumentError, ~r/not a plain snake_case SQL identifier/, fn ->
          Column.swap(bad, Ecto.UUID.generate(), "a", "b")
        end
      end
    end

    test "reads nothing rather than raising on a table that does not exist yet" do
      refute Column.table_present?("op.no_such_table")
      assert Column.matching({"op.no_such_table", "isbn"}, "^x$") == []
      assert Column.by_ids({"op.no_such_table", "isbn"}, [Ecto.UUID.generate()]) == %{}
    end
  end

  describe "a correction over a column that is not isbn" do
    setup do
      book = insert(:editionless_book)
      id = Ecto.UUID.generate()

      Repo.query!(
        """
        INSERT INTO op.book_editions
          (id, book_id, isbn, is_primary, verification_source, created_at, updated_at)
        VALUES ($1, $2, '9780071615693', true, 'barcode_unverified', now(), now())
        """,
        [Ecto.UUID.dump!(id), Ecto.UUID.dump!(book.id)]
      )

      %{id: id}
    end

    defp verification_source_of(id) do
      %{rows: [[source]]} =
        Repo.query!("SELECT verification_source FROM op.book_editions WHERE id = $1", [
          Ecto.UUID.dump!(id)
        ])

      source
    end

    test "is not registered — the shape exists, the disposition is #370's to decide" do
      refute RelabelVerificationSource in Registry.all()
      assert :error = Registry.fetch("test_relabel_verification_source")
    end

    test "dry-runs, reporting the row without touching it", ctx do
      assert {:ok, outcome} = DataCorrection.run(RelabelVerificationSource)

      assert outcome.mode == :dry_run
      assert Enum.any?(outcome.changes, &(&1.id == ctx.id))
      assert verification_source_of(ctx.id) == "barcode_unverified"
      assert audit_rows() == []
    end

    test "applies, audits, and the second run is a no-op", ctx do
      assert {:ok, %{mode: :applied}} =
               DataCorrection.run(RelabelVerificationSource, apply: true, invoked_by: "test")

      assert verification_source_of(ctx.id) == "open_library"

      applied = length(audit_rows())
      assert applied > 0

      assert {:ok, %{count: 0}} =
               DataCorrection.run(RelabelVerificationSource, apply: true, invoked_by: "test")

      assert length(audit_rows()) == applied
      assert verification_source_of(ctx.id) == "open_library"
    end

    test "the write satisfies the column's CHECK constraint", ctx do
      DataCorrection.run(RelabelVerificationSource, apply: true, invoked_by: "test")

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.transaction(fn ->
                 case Repo.query(
                        "UPDATE op.book_editions SET verification_source = 'invented' WHERE id = $1",
                        [Ecto.UUID.dump!(ctx.id)]
                      ) do
                   {:ok, result} -> result
                   {:error, error} -> Repo.rollback(error)
                 end
               end)
    end
  end

  describe "unreachable-table guard" do
    test "reads nothing rather than raising on a table that does not exist yet" do
      refute Column.table_present?("op.no_such_table")
      assert Column.matching({"op.no_such_table", "isbn"}, "^x$") == []
      assert Column.by_ids({"op.no_such_table", "isbn"}, [Ecto.UUID.generate()]) == %{}
    end
  end
end
