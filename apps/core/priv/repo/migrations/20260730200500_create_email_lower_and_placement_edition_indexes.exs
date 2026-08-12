defmodule Core.Repo.Migrations.CreateEmailLowerAndPlacementEditionIndexes do
  @moduledoc """
      The two 335 indexes, split out so both build CONCURRENTLY (`op.users`
      is the auth hot path; squawk requires it): `users_lower_email_index`
      (case-insensitive login-key uniqueness, mirroring the handle index; the
      exact-match index is kept for FK lookups) and
      `bookshelf_placements_book_edition_id_index` (the un-enrichment join).
      Concurrent builds can't run in a transaction — hence
      `@disable_ddl_transaction`/`@disable_migration_lock`, and why the
      downcase and backfill live elsewhere.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists unique_index(:users, ["lower(email)"],
                           prefix: "op",
                           name: :users_lower_email_index,
                           concurrently: true
                         )

    create_if_not_exists index(:bookshelf_placements, [:book_edition_id],
                           prefix: "op",
                           concurrently: true
                         )
  end

  def down do
    drop_if_exists index(:bookshelf_placements, [:book_edition_id],
                     prefix: "op",
                     concurrently: true
                   )

    drop_if_exists index(:users, ["lower(email)"],
                     prefix: "op",
                     name: :users_lower_email_index,
                     concurrently: true
                   )
  end
end
