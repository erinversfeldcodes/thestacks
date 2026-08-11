defmodule Core.Repo.Migrations.AddUserIdFkToUploadedImages do
  @moduledoc """
  Give `op.uploaded_images.user_id` a real foreign key to `op.users` with
  `ON DELETE CASCADE` (Issue #353).

  The column was added by `20260401074249_add_user_id_to_uploaded_images` as a
  bare `:binary_id` with no `references(...)`, so `repo.delete(user)` left every
  one of the erased user's uploaded-image rows behind — user_id and the R2
  storage key intact — and the erasure schema-guard, which enumerates FKs that
  *reference* `op.users`, never inspected the table. A time-based (30-day TTL)
  retention sweep bounded the residue but is retention, not the right to
  erasure. `uploaded_images` holds no user-authored free-text (only a storage
  key, status, and timestamps), so CASCADE fully de-links the user — no SET NULL
  allowlist entry is needed.

  ## Pre-clean: orphan user_id values

  A pre-existing row whose `user_id` points at no `op.users` row would fail the
  constraint scan. Such a row is leaked residue — a user_id with no user is not
  data anyone can be linked to and cannot be exported or re-associated — so it
  is DELETED, not repaired: for an erasure-linkage column, deleting the orphan
  is the correct disposition (the same choice `20260730200200` made for orphan
  auth-session rows). Rows with a NULL `user_id` are left untouched; a NULL FK
  is unconstrained and names no user.

  ## NOT VALID here, VALIDATE separately

  The constraint is added `NOT VALID` so the `ADD CONSTRAINT` takes only a brief
  lock and does not scan the whole table under `ACCESS EXCLUSIVE` (squawk
  `constraint-missing-not-valid` / `adding-foreign-key-constraint`). The scan is
  performed by `20260805100100`, which runs OUTSIDE a transaction so the
  `VALIDATE CONSTRAINT` takes only `SHARE UPDATE EXCLUSIVE`.
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
