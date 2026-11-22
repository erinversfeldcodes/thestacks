defmodule Core.Repo.Migrations.CascadeThePlacementOwnerToUserErasure do
  use Ecto.Migration

  # Add the foreign key NOT VALID first — a brief catalog-only lock, no table
  # scan — then VALIDATE it as a second statement, which takes only SHARE UPDATE
  # EXCLUSIVE and lets writes continue during the scan. A plain validating
  # `ADD CONSTRAINT … FOREIGN KEY` would scan under SHARE ROW EXCLUSIVE and block
  # writes, which is the lock every other migration in this change is careful to
  # avoid. @disable_ddl_transaction so the two run as separate statements rather
  # than holding the ADD's lock across the VALIDATE scan.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # The denormalised owner must be reachable by erasure the same way every other
  # user-scoping column is: a CASCADE foreign key to op.users. Without it,
  # `repo.delete(user)` would not reach these rows through the user_id path — the
  # rows do still die, via the existing bookshelf_id → bookshelves → users
  # cascade, but a bare user column is invisible to the schema-level erasure
  # guard and to the cascade audit, which is a guarantee the system keeps
  # structurally rather than by one reviewer remembering the second path.
  #
  # Kept as its own migration rather than folded into the generated ADD COLUMN:
  # that one is `mix proto.sync` output and the manifest carries user_id as a
  # plain binary_id, so the foreign key is added here by hand instead.
  def up do
    execute("SET lock_timeout = '5s'")

    execute("""
    ALTER TABLE op.bookshelf_placements
      ADD CONSTRAINT bookshelf_placements_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES op.users(id) ON DELETE CASCADE
      NOT VALID
    """)

    execute(
      "ALTER TABLE op.bookshelf_placements VALIDATE CONSTRAINT bookshelf_placements_user_id_fkey"
    )
  end

  def down do
    execute(
      "ALTER TABLE op.bookshelf_placements DROP CONSTRAINT bookshelf_placements_user_id_fkey"
    )
  end
end
