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

      ⛔ `statement_timeout = 0`, MATCHING THE PRECEDENT, and an earlier version
      of this file capped it at 60s. The cap is the wrong shape here: a
      `VALIDATE CONSTRAINT` is a full table scan whose duration is a function of
      table size, not of anything this migration controls, and the scan holds
      only SHARE UPDATE EXCLUSIVE — readers and writers continue throughout, so
      there is nothing to protect them from.
      
      ⚠️ And the failure it would cause is QUIET, which is why it is worth
      fixing while both tables are still small enough that it cannot bite. If
      the scan exceeded the cap, the migration fails and the constraints stay
      `NOT VALID` — which still checks new writes. So new rows are guarded,
      pre-existing bad rows are never caught, and nothing afterwards says the
      validation did not finish. That is a gate that looks enforced and is half
      enforced.

      ⚖️ Plain `SET` under `@disable_ddl_transaction`, since there is no
      transaction for a LOCAL setting to scope to.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  # ⛔ ITS PAIR, AND IT MATTERS MORE BECAUSE OF THE LINE ABOVE IT.
  #
  # At a bounded `statement_timeout` the advisory lock this holds was bounded
  # too. With the timeout at 0 the scan is unbounded by design, so without this
  # Ecto holds the GLOBAL migration lock for the scan's whole duration and a
  # second node's `mix ecto.migrate` — or a concurrent deploy — blocks behind it
  # for as long as it runs. Both precedents carry the pair, and this was the
  # only non-transactional migration in its set missing it.
  @disable_migration_lock true

  def up do
    execute("SET lock_timeout = '5s'")
    execute("SET statement_timeout = 0")

    execute(
      "ALTER TABLE op.post_book_associations VALIDATE CONSTRAINT post_book_associations_confidence_in_range"
    )

    execute(
      "ALTER TABLE op.discovered_sources VALIDATE CONSTRAINT discovered_sources_confidence_in_range"
    )

    # ⚖️ RESET, because a plain `SET` is CONNECTION-scoped and outlives this
    # migration. `SET LOCAL` in a later migration reverts at COMMIT to the
    # SESSION value — whatever the last plain `SET` left — not to the server
    # default, so `statement_timeout = 0` would be inherited by anything
    # relying on a scoped setting rather than stating its own.
    #
    # ⚠️ Only the timeout, and only here. `0` is the one value where inheriting
    # it is actively dangerous: an unbounded timeout is the opposite of the
    # guarantee every other migration in this repo asserts. A leaked
    # `lock_timeout = '5s'` is harmless or helpful, so it is left rather than
    # reset for symmetry.
    execute("RESET statement_timeout")
  end

  def down do
    :ok
  end
end
