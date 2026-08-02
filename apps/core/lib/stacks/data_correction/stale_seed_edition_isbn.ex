defmodule Stacks.DataCorrection.StaleSeedEditionIsbn do
  @moduledoc """
  Re-syncs three seeded editions to the ISBN `seeds.exs` now declares for them
  (Issue #339).

  ## What these rows are

  Staging carries three editions whose ISBN is thirteen digits with the wrong
  EAN-13 check digit. Unlike the ISBN-10s that
  `Stacks.DataCorrection.NormaliseEditionIsbn10` repairs, a wrong check digit
  means one of the thirteen digits is wrong and the row itself cannot say which
  — there is no arithmetic that recovers the intended value, and recomputing the
  check digit in general would mint a syntactically valid ISBN identifying some
  *other* book. That would be fabrication, not repair.

  These three are the exception, and only because their provenance is not in
  doubt:

    * their ids are `Seeds.uuid(3000 + index)` values — deterministic fixture
      UUIDs that no production write path can produce;
    * `created_at` is `2026-01-01T00:00:00Z`, the seed's `jan_01` constant;
    * `open_library_id` and `google_books_id` are both NULL, so nothing was ever
      resolved against an external catalogue;
    * `git log -S` places each of the three literals in `seeds.exs` from the
      works/editions restructure until Issue #335 corrected them in place.

  For a fixture row, `seeds.exs` **is** the correct value, and it already states
  one. So this is not a guess about a book; it is a stale fixture catching up
  with the file that owns it. The `from` values are pinned so the correction can
  only ever touch a row that still holds the exact pre-#335 literal.

  ## Why not delete them

  Deleting was the obvious alternative and is wrong here: on staging all three
  are their work's only edition and carry live placements (1, 2 and 1
  respectively). Dropping them would empty a seeded reader's shelf and remove
  three works from the catalogue to fix a check digit. Re-seeding does not help
  either — `seeds.exs` inserts with `on_conflict: :nothing` keyed on the fixture
  UUID, so the corrected literal can never overwrite the row already there.

  ## One-way

  There is no inverse: the previous value was not a valid ISBN, so nothing
  should ever restore it. The audit row records it if the history is ever needed.

  ## Scope

  Exactly the three enumerated `(id, from)` pairs. The ids do not exist in
  production, so this correction is a no-op there and cannot reach a row a
  reader created.
  """

  @behaviour Stacks.DataCorrection

  alias Stacks.DataCorrection.EditionIsbn

  # {fixture id, the pre-#335 seed literal, the literal seeds.exs declares today}
  # `seed_honesty_test.exs` asserts each `to` is present in seeds.exs and each
  # `from` is absent, so this table cannot drift from the file it mirrors.
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
