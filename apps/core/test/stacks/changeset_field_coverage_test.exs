defmodule Stacks.ChangesetFieldCoverageTest do
  @moduledoc """
    Every proto-generated schema field must be castable by its changeset
    or explicitly skip-listed with a reason. Changesets are hand-written
    (so validation survives regeneration), which sets a trap: `mix
    proto.sync` adds the column to the schema but NOT the cast list, and
    writes to the new field drop in complete silence. This walks every
    persisted schema's fields against its changeset's cast set.
  """

  use ExUnit.Case, async: true

  alias Stacks.Enrichment

  @changesets %{
    Stacks.Enrichment.ThirdSpace => {&Enrichment.third_space_changeset/2, []},
    Stacks.Enrichment.BookstoreEvent => {&Enrichment.bookstore_event_changeset/2, []},
    Stacks.Enrichment.ThirdSpaceEvent => {&Enrichment.third_space_event_changeset/2, []},
    Stacks.Enrichment.ReviewSnapshot => {&Enrichment.review_snapshot_changeset/2, []},
    Stacks.Enrichment.PriceSnapshot => {&Enrichment.price_snapshot_changeset/2, []},
    Stacks.Enrichment.DiscoveredSource =>
      {&Enrichment.discovered_source_changeset/2,
       [
         :exclusion_requested_at
       ]}
  }

  @never_cast [:id, :created_at, :updated_at, :inserted_at]

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
