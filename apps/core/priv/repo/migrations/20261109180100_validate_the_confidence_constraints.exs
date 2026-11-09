defmodule Core.Repo.Migrations.ValidateTheConfidenceConstraints do
  @moduledoc """
      Validate the two `confidence` range constraints `…180000` added `NOT VALID`.

      ⚖️ Its own migration, because that is the only way the separation is real.
      A `VALIDATE CONSTRAINT` in the same file as its `ADD … NOT VALID` runs in
      the same transaction and blocks all reads for the length of the scan,
      which defeats the entire reason for splitting — and `squawk` flags it,
      correctly, because the file is what it can see.

      ⬛ The VALIDATE takes only a `SHARE UPDATE EXCLUSIVE` lock, so concurrent
      reads and writes continue while it scans. That is the property the split
      buys, and it is bought by being a separate transaction rather than by
      being described as one.

      ⚠️ Idempotent by construction: validating an already-valid constraint is a
      no-op in Postgres, so a partial deploy that ran this and failed later can
      re-run it. `down` is deliberately empty — "un-validating" a constraint is
      not an operation, and dropping it belongs to `…180000`'s `down`.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute(
      "ALTER TABLE op.post_book_associations VALIDATE CONSTRAINT post_book_associations_confidence_in_range"
    )

    execute(
      "ALTER TABLE op.discovered_sources VALIDATE CONSTRAINT discovered_sources_confidence_in_range"
    )
  end

  def down do
    :ok
  end
end
