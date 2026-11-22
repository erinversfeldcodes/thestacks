defmodule Core.Repo.Migrations.CascadeThePlacementOwnerToUserErasure do
  use Ecto.Migration

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
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    ALTER TABLE op.bookshelf_placements
      ADD CONSTRAINT bookshelf_placements_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES op.users(id) ON DELETE CASCADE
    """)
  end

  def down do
    execute(
      "ALTER TABLE op.bookshelf_placements DROP CONSTRAINT bookshelf_placements_user_id_fkey"
    )
  end
end
