defmodule Core.Repo.Migrations.CreateEmailLowerAndPlacementEditionIndexes do
  @moduledoc """
  The two indexes Issue #335 needs, split out so both can be built
  CONCURRENTLY — squawk's `require-concurrent-index-creation` gate, and more to
  the point `op.users` is the auth hot path and must not take a write-blocking
  lock. A concurrent build cannot run inside a transaction, hence
  `@disable_ddl_transaction` / `@disable_migration_lock`; that in turn is why
  neither the email downcase (`20260730200400`) nor the placement backfill
  (`20260730200100`) lives here.

    * `users_lower_email_index` — case-insensitive uniqueness on the login key.
      Mirrors `users_lower_handle_index` (`20260714200520`). The pre-existing
      exact-match `users_email_index` is deliberately KEPT: it is the index
      `Accounts.registration_changeset/2`'s `unique_constraint(:email)` names by
      default, so dropping it would turn a friendly "has already been taken"
      changeset error into a raised Postgrex error.

    * `bookshelf_placements_book_edition_id_index` — the reverse side of the
      `book_edition_id` FK added in `20260730193135`. Without it, deleting an
      edition sequentially scans every placement to apply ON DELETE SET NULL,
      and the per-edition ownership queries this column exists to enable have no
      access path.

  Idempotent (`create_if_not_exists`): previews and staging environments that
  ran an earlier revision of this branch already carry them.
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
