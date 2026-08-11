defmodule Core.Repo.Migrations.AddOwnerFksToAuthSessionTables do
  @moduledoc """
    Adds the two FKs GDPR erasure was compensating for in application code: `auth_token_families.user_id` and `guardian_tokens.sub` named
    users with no FK, so `repo.delete(user)` left live session state behind
    and only the hand-rolled `:revoke_sessions` step cleaned it. Now the
    database owns it — any delete path takes the sessions along.
    `guardian_tokens` needs a generated uuid column over `sub` (guardian_db
    owns that column's text type); added `NOT VALID`, validated in
    `20260730200350`.
  """
  use Ecto.Migration

  @uuid_re "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

  def up do
    execute("""
    DELETE FROM op.auth_token_families f
    WHERE NOT EXISTS (SELECT 1 FROM op.users u WHERE u.id = f.user_id)
    """)

    execute("""
    ALTER TABLE op.auth_token_families
      ADD CONSTRAINT auth_token_families_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES op.users (id) ON DELETE CASCADE NOT VALID
    """)

    execute("""
    DELETE FROM op.guardian_tokens
    WHERE sub IS NOT NULL AND sub <> '' AND sub !~ '#{@uuid_re}'
    """)

    execute("""
    DELETE FROM op.guardian_tokens t
    WHERE t.sub IS NOT NULL AND t.sub <> ''
      AND NOT EXISTS (SELECT 1 FROM op.users u WHERE u.id = t.sub::uuid)
    """)

    execute("""
    ALTER TABLE op.guardian_tokens
      ADD COLUMN user_id uuid GENERATED ALWAYS AS (NULLIF(sub, '')::uuid) STORED
    """)

    execute("""
    ALTER TABLE op.guardian_tokens
      ADD CONSTRAINT guardian_tokens_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES op.users (id) ON DELETE CASCADE NOT VALID
    """)
  end

  @breaking_ok "op.guardian_tokens.user_id is introduced by THIS migration's up/0; the down/0 drop removes only what it added, and nothing reads the column (it exists solely to carry the FK)."

  def down do
    execute("""
    ALTER TABLE op.guardian_tokens DROP CONSTRAINT IF EXISTS guardian_tokens_user_id_fkey
    """)

    execute("""
    -- squawk-ignore ban-drop-column
    ALTER TABLE op.guardian_tokens DROP COLUMN IF EXISTS user_id
    """)

    execute("""
    ALTER TABLE op.auth_token_families DROP CONSTRAINT IF EXISTS auth_token_families_user_id_fkey
    """)
  end
end
