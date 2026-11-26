defmodule Core.Repo.Migrations.LetTheAuditSweepFindItsRowsByIndex do
  @moduledoc """
      Adds `audit.audit_log(occurred_at)`, so the retention sweep can select the
      rows it deletes instead of scanning the whole table for them.

      ## The claim this repairs

      `Stacks.Workers.AuditRetentionJob`'s own moduledoc records the defect
      plainly, having caught itself: it had described the sweep as "a nightly job
      on an indexed timestamp", and that was **false**. The only index touching
      `occurred_at` was `(user_id, occurred_at)`, which cannot drive
      `WHERE occurred_at < $1` with no `user_id` predicate — a composite index is
      only usable from its leading column. `EXPLAIN` against the real table
      returned a Seq Scan.

      So the nightly DELETE sequentially scanned a table whose whole design is to
      grow forever and never be updated. Survivable at today's volume, and the
      wrong shape for a first run against a long backlog — which is exactly the
      run that matters, because it is the one with the most rows.

      ## Why CONCURRENTLY

      `audit.audit_log` is append-only and written on the request path by
      `Stacks.Audit`, so a plain `CREATE INDEX` holding a lock against writes
      would stall audited requests for the duration. Concurrent creation needs
      its own transaction, hence `@disable_ddl_transaction`, and
      `statement_timeout = 0` because a timeout firing mid-build leaves an
      INVALID index behind — worse than not having started.

      ⚠️ `SET`, not `SET LOCAL`: with no transaction there is nothing for a LOCAL
      setting to scope to, and it would silently apply to nothing.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("SET lock_timeout = '5s'")
    execute("SET statement_timeout = 0")

    create_if_not_exists index(:audit_log, [:occurred_at],
                           prefix: "audit",
                           name: :audit_log_occurred_at_index,
                           concurrently: true
                         )
  end

  def down do
    execute("SET lock_timeout = '5s'")
    execute("SET statement_timeout = 0")

    drop_if_exists index(:audit_log, [:occurred_at],
                     prefix: "audit",
                     name: :audit_log_occurred_at_index,
                     concurrently: true
                   )
  end
end
