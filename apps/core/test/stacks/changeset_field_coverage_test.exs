defmodule Stacks.ChangesetFieldCoverageTest do
  @moduledoc """
  Every proto-generated schema field must be **castable** by its changeset, or explicitly
  skip-listed with a reason.

  ## Why this exists

  Changesets in this project are hand-written on purpose so validation survives schema
  regeneration (`Stacks.Enrichment`'s moduledoc says so). The cost of that choice is a trap:
  `mix proto.sync` adds a column to the generated schema and **does not** add it to the
  cast list, so writes to the new field are dropped **in complete silence** — no error, no
  warning, just a nil column.

  That happened three times in one day on 2026-07-28:

    * `latitude` / `longitude` / `nearest_bookshop_km` on `third_spaces` — every space was
      created unpositioned, and it took a failing feature test to notice;
    * caught again immediately after for `curated` / `curated_note`, only because the first
      one had just taught the lesson.

  `Stacks.FactoryProtoValidationTest` already guards the *fixture* side of the same gap.
  This is the *write* side, and the pair of them means "add a proto field" fails pre-merge
  in both places it is normally forgotten.

  ## How it works — behaviour, not source text

  Rather than parsing cast lists (which would break the moment someone builds one from a
  module attribute, as several of these do), each changeset is **called** with a map
  containing every schema field, and the result's `changes` are inspected. A field absent
  from `changes` was silently dropped by the cast — which is exactly the defect.

  So this asserts what the changeset *does*, not what it looks like.
  """

  use ExUnit.Case, async: true

  alias Stacks.Enrichment

  # schema => {changeset function, fields legitimately not castable}
  #
  # A skip entry is a claim that the field is written by something other than this
  # changeset — a probe, a job, a database default. Each one should be obvious from the
  # field's own documentation; if it is not, it probably belongs in the cast list.
  @changesets %{
    Stacks.Enrichment.ThirdSpace =>
      {&Enrichment.third_space_changeset/2,
       [
         # Written only by `Discovery.create_third_space/1`'s geocoding step... which uses
         # this changeset, so these ARE cast. Nothing to skip.
       ]},
    Stacks.Enrichment.BookstoreEvent => {&Enrichment.bookstore_event_changeset/2, []},
    Stacks.Enrichment.ThirdSpaceEvent => {&Enrichment.third_space_event_changeset/2, []},
    Stacks.Enrichment.ReviewSnapshot => {&Enrichment.review_snapshot_changeset/2, []},
    Stacks.Enrichment.PriceSnapshot => {&Enrichment.price_snapshot_changeset/2, []},
    Stacks.Enrichment.DiscoveredSource =>
      {&Enrichment.discovered_source_changeset/2,
       [
         # The creation changeset deliberately cannot set these: a source is not created
         # already-excluded or already-requested. `discovered_source_status_changeset/2`
         # owns them, and is covered by its own entry below.
         :exclusion_requested_at
       ]}
  }

  # Fields no changeset should ever cast: the database owns them.
  @never_cast [:id, :created_at, :updated_at, :inserted_at]

  # A value the field's Ecto type will accept, so `cast/3` does not reject it for the
  # wrong reason — a type mismatch would look identical to a missing cast entry.
  defp sample(:string), do: "sample"
  defp sample(:integer), do: 1
  defp sample(:float), do: 1.0
  defp sample(:boolean), do: true
  defp sample(:binary_id), do: Ecto.UUID.generate()
  defp sample(:utc_datetime_usec), do: DateTime.utc_now()
  defp sample(:utc_datetime), do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp sample(:date), do: Date.utc_today()
  defp sample(:map), do: %{}
  defp sample({:array, inner}), do: [sample(inner)]
  defp sample(:decimal), do: Decimal.new("1.0")
  # Ecto.Enum and other parameterised types: fall back to the first permitted value.
  defp sample({:parameterized, _, %{on_load: on_load}}) when is_map(on_load),
    do: on_load |> Map.keys() |> List.first()

  defp sample(_other), do: "sample"

  for {schema, {changeset_fun, skips}} <- @changesets do
    @schema schema
    @changeset_fun changeset_fun
    @skips skips

    test "#{inspect(schema)}'s changeset can write every schema field" do
      all_fields = @schema.__schema__(:fields)

      invalid_skips = @skips -- all_fields

      assert invalid_skips == [],
             "skip list names fields that do not exist: #{inspect(invalid_skips)}"

      candidates = all_fields -- (@never_cast ++ @skips)

      attrs =
        Map.new(candidates, fn field ->
          {field, sample(@schema.__schema__(:type, field))}
        end)

      changeset = @changeset_fun.(struct(@schema), attrs)
      dropped = candidates -- Map.keys(changeset.changes)

      assert dropped == [],
             """
             These fields exist on #{inspect(@schema)} but the changeset silently drops them:

                 #{inspect(dropped)}

             `mix proto.sync` adds columns to the generated schema; it does NOT add them to
             hand-written cast lists. A write to a dropped field fails with no error at all —
             the column just stays nil.

             Fix: add them to the changeset's cast list, or to this test's skip list with a
             note saying what else writes them. Run `just proto-field-check` for the full
             list of follow-ons.
             """
    end
  end

  describe "the status changeset for discovered sources" do
    test "can write the exclusion fields the creation changeset deliberately cannot" do
      # The other half of the split above: recording a removal request is a status
      # transition, not a creation, and `exclusion_requested_at` distinguishes
      # "asked for" from "applied".
      changeset =
        Enrichment.discovered_source_status_changeset(
          %Stacks.Enrichment.DiscoveredSource{},
          %{
            status: "excluded",
            excluded_at: DateTime.utc_now(),
            exclusion_email: "owner@example.test",
            exclusion_requested_at: DateTime.utc_now()
          }
        )

      for field <- [:status, :excluded_at, :exclusion_email, :exclusion_requested_at] do
        assert Map.has_key?(changeset.changes, field),
               "the status changeset drops #{field}, so a removal request cannot be recorded"
      end
    end
  end
end
