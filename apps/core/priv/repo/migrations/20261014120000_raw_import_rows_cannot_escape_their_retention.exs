defmodule Core.Repo.Migrations.RawImportRowsCannotEscapeTheirRetention do
  @moduledoc """
      Closes a retention hole in `op.library_import_rows`, and takes the index
      the sweep that enforces that retention actually needs.

      ## The hole

      A raw import row carries the reader's own free text — their Goodreads
      reviews and their private notes. It exists to power the one-time per-row
      report and is deleted after 30 days by `LibraryImportRowRetentionJob`,
      whose sweep is `where created_at < cutoff`.

      `created_at` was nullable with no default. A NULL never satisfies
      `< cutoff`, so a row without one is swept NEVER: the reader's reviews and
      notes stay in the table permanently, and nothing says so. The sweep's own
      log line reports what it deleted, not what it could not see.

      No such row exists today — `Imports.insert_import/3` is the only writer
      and it merges `created_at` into every row before `insert_all`. That is
      precisely why this is worth closing now rather than after it happens: the
      guarantee currently rests on one caller remembering, in a table whose
      whole purpose is to not keep what it holds, and `insert_all` bypasses the
      changeset and the schema default alike. The same shape as the
      never-expiring invitation the sweep could not age.

      ## Why the DEFAULT as well as the constraint

      The constraint alone would turn a future writer that forgets the column
      into a failed import. The default makes it correct instead: `now()` at
      insert IS what this column means ("when the row was parsed"), so a writer
      that omits it gets the right value rather than an error — and the
      retention clock starts, which is the point.

      ## Why a CHECK rather than `SET NOT NULL`

      `ALTER COLUMN … SET NOT NULL` takes ACCESS EXCLUSIVE for the length of a
      full table scan, blocking reads as well as writes. A `CHECK (… IS NOT
      NULL)` added `NOT VALID` and validated in a later migration enforces the
      same thing on every write, and its scan runs under SHARE UPDATE
      EXCLUSIVE. That is the shape the lockout-state constraint already uses
      here, and the one the migration lint asks for.

      ## Backfill

      From the PARENT IMPORT's `created_at`, not from `now()`. The join is total
      (`import_id` is NOT NULL and cascades), so every row gets a value. The
      parent's timestamp is marginally earlier than the row's real parse time,
      which can only age a row EARLIER into the sweep window — never later, so
      no row's retention is extended by the repair. `now()` would write a value
      that is knowingly false and would reset the retention clock on text that
      is already past its 30 days, which is the opposite of what this fixes.

      Rows that become immediately sweepable as a result are rows whose
      retention already expired. The next nightly sweep deleting them is the
      obligation being met, not a loss.

      ## The indexes

      `created_at` gets one: the retention sweep filters on it alone and had no
      index to use, so the one query whose job is to delete the reader's free
      text on time was a full scan of the table that holds it.

      The single-column `import_id` index goes: a btree on `(import_id,
      row_number)` already serves every predicate on `import_id` alone,
      including the cascade's, and so does `(import_id, outcome)`. Three indexes
      led by the same column is write cost for no read it can answer alone.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  @disable_migration_lock true

  def up do
    execute("""
    UPDATE op.library_import_rows r
       SET created_at = i.created_at
      FROM op.library_imports i
     WHERE i.id = r.import_id
       AND r.created_at IS NULL
    """)

    execute("ALTER TABLE op.library_import_rows ALTER COLUMN created_at SET DEFAULT now()")

    execute("""
    ALTER TABLE op.library_import_rows
      ADD CONSTRAINT library_import_rows_created_at_present
      CHECK (created_at IS NOT NULL)
      NOT VALID
    """)

    create index(:library_import_rows, [:created_at], prefix: "op", concurrently: true)

    drop_if_exists index(:library_import_rows, [:import_id], prefix: "op", concurrently: true)
  end

  def down do
    create_if_not_exists index(:library_import_rows, [:import_id],
                           prefix: "op",
                           concurrently: true
                         )

    drop_if_exists index(:library_import_rows, [:created_at], prefix: "op", concurrently: true)

    execute("""
    ALTER TABLE op.library_import_rows
      DROP CONSTRAINT IF EXISTS library_import_rows_created_at_present
    """)

    execute("ALTER TABLE op.library_import_rows ALTER COLUMN created_at DROP DEFAULT")
  end
end
