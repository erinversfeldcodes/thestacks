defmodule Core.Repo.Migrations.ConstrainTheEnumerationsTheChangesetsAlreadyCheck do
  @moduledoc """
      Moves five value sets from a changeset into the column that holds them.

      Each of these is already enumerated in Elixir and validated on the one
      write path that happens to go through a changeset:

        | Column                              | Set                                               | Validated in |
        |-------------------------------------|---------------------------------------------------|--------------|
        | `platform_costs.category`           | hosting · compute · database · domain · services  | `Costs.platform_cost_changeset/2` |
        | `platform_costs.amount_cents`       | `>= 0`                                            | same |
        | `library_imports.status`            | enqueued · running · complete · failed            | `Imports.mark_running/1`, `finalize/2` guards |
        | `library_import_rows.outcome`       | shelved · duplicate · unverified · unreadable     | **nowhere** — see below |
        | `post_syndications.target`/`method` | substack · rss/export                             | `Syndication.syndication_changeset/2` |

      ## Why the column and not the changeset

      A changeset only binds the writes that go through it, and three of these
      tables are written by paths that do not: `Imports.insert_import/3` uses
      `insert_all` (no changeset at all), the import worker writes `status`
      through `Ecto.Changeset.change/2` (cast, not validated), and every test
      factory inserts the struct directly.

      That last one is not hypothetical. The cost factory handed out a category
      outside the valid set for months and no test noticed, because the factory
      never touches the changeset — the defect was found by reading, not by a
      failure. A constraint here would have reddened every test that used the
      factory on the day it was written, and it defends the write paths that do
      not exist yet, which is the half a changeset can never cover.

      ⚠️ `library_import_rows.outcome` is the sharpest case and an earlier draft
      of this note got it wrong, claiming `Imports.record_outcome/3` validated
      it. That function uses `Ecto.Changeset.change/2` — cast, no validation —
      and `Repo.update!`, so the value was checked **nowhere at all** before
      this constraint, on a column written exclusively from inside an Oban job.
      A `validate_inclusion` was added alongside this migration so the job fails
      on its own changeset rather than on a database error three frames down.

      `outcome` stays nullable on purpose: it is empty until the row is
      processed, and an unprocessed row is a legitimate state rather than a
      missing value.

      Each constraint is added `NOT VALID` and validated in the following
      migration, so no full-table scan runs under ACCESS EXCLUSIVE.
  """
  use Ecto.Migration

  # This one runs in a transaction, so the settings are `SET LOCAL` and revert on
  # commit. Both are short: `ADD CONSTRAINT ... NOT VALID` takes ACCESS EXCLUSIVE
  # but does no scan, so it is a millisecond operation that should never be
  # waiting — if it is, something long-running holds the table and the right
  # answer is to abort and retry rather than to block every reader behind us.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute("""
    ALTER TABLE op.platform_costs
      ADD CONSTRAINT platform_costs_category_known
      CHECK (category IN ('hosting', 'compute', 'database', 'domain', 'services'))
      NOT VALID
    """)

    execute("""
    ALTER TABLE op.platform_costs
      ADD CONSTRAINT platform_costs_amount_not_negative
      CHECK (amount_cents >= 0)
      NOT VALID
    """)

    execute("""
    ALTER TABLE op.library_imports
      ADD CONSTRAINT library_imports_status_known
      CHECK (status IN ('enqueued', 'running', 'complete', 'failed'))
      NOT VALID
    """)

    execute("""
    ALTER TABLE op.library_import_rows
      ADD CONSTRAINT library_import_rows_outcome_known
      CHECK (
        outcome IS NULL
        OR outcome IN ('shelved', 'duplicate', 'unverified', 'unreadable')
      )
      NOT VALID
    """)

    execute("""
    ALTER TABLE op.post_syndications
      ADD CONSTRAINT post_syndications_target_and_method_known
      CHECK (target = 'substack' AND method IN ('rss', 'export'))
      NOT VALID
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute(
      "ALTER TABLE op.post_syndications DROP CONSTRAINT IF EXISTS post_syndications_target_and_method_known"
    )

    execute(
      "ALTER TABLE op.library_import_rows DROP CONSTRAINT IF EXISTS library_import_rows_outcome_known"
    )

    execute(
      "ALTER TABLE op.library_imports DROP CONSTRAINT IF EXISTS library_imports_status_known"
    )

    execute(
      "ALTER TABLE op.platform_costs DROP CONSTRAINT IF EXISTS platform_costs_amount_not_negative"
    )

    execute(
      "ALTER TABLE op.platform_costs DROP CONSTRAINT IF EXISTS platform_costs_category_known"
    )
  end
end
