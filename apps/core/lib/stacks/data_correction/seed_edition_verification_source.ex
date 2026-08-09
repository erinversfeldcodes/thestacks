defmodule Stacks.DataCorrection.SeedEditionVerificationSource do
  @moduledoc """
  Restores the seed's declared provenance to seed-fixture editions the #335
  backfill labelled `barcode_unverified` (Issue #370).

  ## What these rows are

  `verification_source` was introduced by migration `20260730193134`; its
  companion backfill (`20260730200000`) filled pre-existing rows from the
  provider identifiers — and deliberately fell back to `barcode_unverified`
  when neither `open_library_id` nor `google_books_id` was recorded. That
  fallback is the honest reading for a row of unknown origin. But the seed
  fixtures predate identifier storage entirely, so on staging (and every Neon
  branch forked from it) ALL of them fell into that bucket: 206 of 206 editions
  read `barcode_unverified`, and every book-detail overlay called its own book
  unidentified beside the card showing its title (#370's live drive).

  `seeds.exs` states its own provenance for exactly these rows — every seeded
  edition is written with `verification_source: "open_library"`, with the
  in-file justification that every seeded ISBN is a real, externally-catalogued
  book. So, as with `StaleSeedEditionIsbn`: for a fixture row, `seeds.exs` is
  the correct value, and this is a stale fixture catching up with the file that
  owns it — not an assertion of a live verification that never happened.

  ## Scope — seed rows only, by construction

  Only rows whose id carries the seed's deterministic UUID prefix
  (`Seeds.uuid/1` → `a1b2c3d4-0000-0000-0000-…`), which no production write
  path can produce (`Ecto.UUID` autogenerates v4 ids). A reader-created edition
  that is genuinely `barcode_unverified` — the barcode fast path, awaiting
  enrichment — is untouched: that label is CORRECT for it, and the UI now
  renders such rows truthfully anyway (`isUnidentified` split from
  `isProvisional`, the code half of #370).

  ## Idempotent and one-way

  A second run plans nothing (no seed row still holds `barcode_unverified`).
  One-way: the previous value was the backfill's conservative default, not
  recorded state — the audit row keeps it if the history is ever needed.
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
