defmodule Stacks.DataCorrection.SeedEditionVerificationSource do
  @moduledoc """
  Restores the seed's declared provenance to seed-fixture editions the 335
  backfill labelled `barcode_unverified` (370). The backfill's fallback was
  honest for rows of unknown origin, but seed fixtures predate identifier
  storage, so on staging all 206 editions fell into it — and every
  book-detail overlay called its own book unidentified. Scopes strictly to
  rows provably seed-authored (deterministic `Seeds.uuid/1` ids); real
  user rows of unknown origin keep the honest label.
  """

  @behaviour Stacks.DataCorrection

  alias Stacks.DataCorrection.Column

  @target {"op.book_editions", "verification_source"}
  @seed_id_prefix "a1b2c3d4-0000-0000-0000-"

  @from "barcode_unverified"
  @to "open_library"

  @doc "The `{table, column}` this correction writes. Exposed for tests."
  @spec target() :: Column.target()
  def target, do: @target

  @impl true
  def name, do: "seed_edition_verification_source"

  @impl true
  def resource_type, do: "book_edition"

  @impl true
  def scope,
    do:
      "seed-fixture editions (deterministic #{@seed_id_prefix}… ids) still carrying " <>
        "the #335 backfill's #{@from} fallback"

  @impl true
  def reversibility,
    do:
      {:one_way,
       "the previous value was the backfill's conservative fallback, not a recorded " <>
         "verification state; the audit row keeps it if the history is ever needed"}

  @impl true
  def plan do
    @target
    |> Column.holding(@from)
    |> Enum.filter(fn {id, _value} -> String.starts_with?(id, @seed_id_prefix) end)
    |> Enum.map(fn {id, from} ->
      %{
        id: id,
        from: from,
        to: @to,
        because:
          "seed fixture predating the #335 verification_source column; seeds.exs " <>
            "declares open_library for every seeded edition"
      }
    end)
  end

  @impl true
  def apply_change(%{id: id, from: from, to: to}), do: Column.swap(@target, id, from, to)
end
