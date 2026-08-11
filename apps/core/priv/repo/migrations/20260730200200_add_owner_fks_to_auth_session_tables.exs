defmodule Core.Repo.Migrations.AddOwnerFksToAuthSessionTables do
  @moduledoc """
  The two user references GDPR erasure has been compensating for in application
  code (Issue #335 D3).

  `op.auth_token_families.user_id` and `op.guardian_tokens.sub` both name a user
  and neither carried a foreign key, so `repo.delete(user)` left live session
  state behind. `Stacks.GDPR.Deletion.delete_user_data/2` papered over that with
  a hand-rolled `:revoke_sessions` step — a guarantee that held only for the one
  code path that remembered to run it. After this migration the database owns
  it: any delete of an `op.users` row, from any path including a bare `psql`
  session, takes the user's sessions with it.

  ## guardian_tokens: why a generated column

  `sub` is guardian_db's own schema (`varchar`, holding the user id as a
  string), and this project does not own that schema — it cannot be retyped to
  `uuid` without forking the library's model. So the owner reference is a
  separate `user_id uuid GENERATED ALWAYS AS (NULLIF(sub, '')::uuid) STORED`
  column carrying the FK. PostgreSQL permits a foreign key on a stored generated
  column (verified against PG 16), and because the value is *derived*, no writer
  — guardian_db, a future refresh path, an operator — can set it inconsistently
  with `sub`. A NULL/empty `sub` yields NULL, which no FK constrains: such a row
  names no user, so erasure has nothing to reach.

  ## Pre-clean

  Both tables may hold rows that predate any enforcement. They are deleted, not
  repaired: an auth session whose user no longer exists is already dead
  (`Guardian.resource_from_claims/1` 401s on a missing user), and a
  `guardian_tokens.sub` that is not a UUID was never a valid subject. The two
  guardian_tokens deletes are kept SEPARATE so the non-UUID rows are gone before
  any statement casts `sub` to `uuid` — a single combined predicate could have
  its casting branch evaluated first and abort the migration.

  Both constraints are added `NOT VALID` here and validated by
  `20260730200350`, which runs OUTSIDE a transaction — validating in this one
  would hold the ACCESS EXCLUSIVE lock across the scan and defeat the point
  (squawk `constraint-missing-not-valid`).
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
