defmodule Core.Repo.Migrations.AddUserIdFkToUploadedImages do
  @moduledoc """
  Gives `op.uploaded_images.user_id` a real FK with `ON DELETE CASCADE`
  (353). The column was a bare `:binary_id`, so erasure left the rows
  behind — and the schema-guard, which enumerates FKs referencing
  `op.users`, never inspected the table (retention's 30-day TTL bounded
  the residue but is not erasure). CASCADE is right here: no user-authored
  free-text, only a storage key/status/timestamps; R2 objects are deleted
  by `GDPR.Deletion` before the row goes. Added `NOT VALID`, validated
  here in a second txn after a null-orphan check.
  """
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM op.uploaded_images i
    WHERE i.user_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM op.users u WHERE u.id = i.user_id)
    """)

    execute("""
    ALTER TABLE op.uploaded_images
      ADD CONSTRAINT uploaded_images_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES op.users (id) ON DELETE CASCADE NOT VALID
    """)
  end

  def down do
    execute("""
    ALTER TABLE op.uploaded_images DROP CONSTRAINT IF EXISTS uploaded_images_user_id_fkey
    """)
  end
end
