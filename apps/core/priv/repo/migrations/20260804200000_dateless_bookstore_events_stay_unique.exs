defmodule Core.Repo.Migrations.DatelessBookstoreEventsStayUnique do
  @moduledoc """
  Bookstore events may have no date (382 ruling): the one real event
  either scrapeable shop publishes is a dateless page, and inventing a
  date is the failure mode this pipeline refuses. The column was already
  nullable — this migration is about the UNIQUE INDEX: Postgres treats
  NULLs as distinct, so the `(store_id, title, event_date)` upsert never
  conflicted for dateless events and every scrape inserted a duplicate.
  Replaced with `NULLS NOT DISTINCT` semantics via a coalescing
  expression index.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

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
