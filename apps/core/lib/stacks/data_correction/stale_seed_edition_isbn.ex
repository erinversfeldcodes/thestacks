defmodule Stacks.DataCorrection.StaleSeedEditionIsbn do
  @moduledoc """
  Re-syncs three seeded editions to the ISBN `seeds.exs` now declares
  (339). A wrong EAN-13 check digit means one of thirteen digits is wrong
  and the row cannot say which — recomputing the digit would mint a valid
  ISBN naming some OTHER book: fabrication, not repair. These three are
  repairable only because provenance is not in doubt (deterministic seed
  UUIDs, the seed's `jan_01` timestamp, no provider ids) and `seeds.exs`
  declares the intended value. Plan matches id AND stale ISBN, so a row
  that drifts is refused.
  """

  @behaviour Stacks.DataCorrection

  alias Stacks.DataCorrection.EditionIsbn

  @fixtures [
    {"a1b2c3d4-0000-0000-0000-000000004076", "9780156030358", "9780156030359"},
    {"a1b2c3d4-0000-0000-0000-000000004096", "9780679775474", "9780679775478"},
    {"a1b2c3d4-0000-0000-0000-000000004117", "9780446611972", "9780446611978"}
  ]

  @doc "The `{id, from, to}` triples this correction claims. Exposed for tests."
  @spec fixtures() :: [{String.t(), String.t(), String.t()}]
  def fixtures, do: @fixtures

  @impl true
  def name, do: "stale_seed_edition_isbn"

  @impl true
  def resource_type, do: "book_edition"

  @impl true
  def scope,
    do: "the three enumerated seed-fixture editions still holding their pre-#335 ISBN literal"

  @impl true
  def reversibility,
    do:
      {:one_way,
       "the previous value was not a valid ISBN, so nothing should restore it; " <>
         "the audit row keeps it if the history is ever needed"}

  @impl true
  def plan do
    current = EditionIsbn.by_ids(Enum.map(@fixtures, fn {id, _from, _to} -> id end))

    for {id, from, to} <- @fixtures, Map.get(current, id) == from do
      %{
        id: id,
        from: from,
        to: to,
        because: "seed fixture predating the seeds.exs ISBN correction in #335"
      }
    end
  end

  @impl true
  def apply_change(%{id: id, from: from, to: to}), do: EditionIsbn.swap(id, from, to)
end
