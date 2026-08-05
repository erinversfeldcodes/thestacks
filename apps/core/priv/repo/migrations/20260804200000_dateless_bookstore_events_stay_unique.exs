defmodule Core.Repo.Migrations.DatelessBookstoreEventsStayUnique do
  @moduledoc """
  Bookstore events may now have no date (#382, owner ruling 2026-08-04): the one real event either
  scrapeable shop publishes is a standalone page with no date anywhere on it, and inventing one is
  the failure mode this pipeline is built to refuse.

  ⚠️ The column was already nullable — this migration exists for the **unique index**. Postgres
  treats NULLs as distinct in a unique index by default, so the upsert on
  `(store_id, title, event_date)` would neither conflict nor replace for a dateless event: every
  scrape run would insert a fresh duplicate of the same page, and `ON CONFLICT` would never fire.
  Idempotency — the property `upsert_event/1` is named for — would hold for dated events and
  silently fail for dateless ones.

  `NULLS NOT DISTINCT` (Postgres 15+; this project pins 16) makes `(store, title, NULL)` collide
  with itself, so the upsert stays an upsert.
  """
  use Ecto.Migration

  # `CREATE/DROP INDEX CONCURRENTLY` cannot run inside a transaction, so opt out of Ecto's
  # migration-wide transaction. Swapping the index concurrently keeps `op.bookstore_events` writable
  # for the rebuild instead of blocking the scrape jobs that write it.
  @disable_ddl_transaction true

  # Ecto holds its advisory migration lock on a separate idle connection for the whole CONCURRENTLY
  # build; Neon drops idle sockets mid-build (300s hang + `ssl send: closed`). Deploys are already
  # serialised by the release pipeline, so releasing the lock is safe. Same rationale as the
  # generated concurrent-index migrations.
  @disable_migration_lock true

  def up do
    drop index(:bookstore_events, [:store_id, :title, :event_date],
           prefix: "op",
           concurrently: true
         )

    create unique_index(:bookstore_events, [:store_id, :title, :event_date],
             prefix: "op",
             nulls_distinct: false,
             concurrently: true
           )
  end

  def down do
    drop index(:bookstore_events, [:store_id, :title, :event_date],
           prefix: "op",
           concurrently: true
         )

    create unique_index(:bookstore_events, [:store_id, :title, :event_date],
             prefix: "op",
             concurrently: true
           )
  end
end
