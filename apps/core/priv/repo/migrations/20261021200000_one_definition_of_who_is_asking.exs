defmodule Core.Repo.Migrations.OneDefinitionOfWhoIsAsking do
  @moduledoc """
      One function owns the question "is there a user", and the grant list stops
      claiming something false about who calls what.

      ## 1. ⛔ A grant I revoked yesterday on a stated reason that was wrong

      `20261021100000` revoked `op.placement_owners_for_edition/1` from PUBLIC —
      correct, it was executable by every role that can connect — and granted it
      to nobody, on this reasoning:

      > a data correction that runs on the owner connection, never on a request.
      > **The application role does not need it and never called it.**

      **The second sentence is false, and measured so.** The unmerge correction
      is reachable over HTTP: `POST /api/admin/data_corrections/:name/target`
      with `apply: true` runs `apply_change/1` in the request, as the runtime
      role, and that calls this function. As `stacks_app`:

          SELECT count(*) FROM op.placement_owners_for_edition(<edition>)
            → ERROR: permission denied for function placement_owners_for_edition

      So yesterday's change closed a real hole and opened a different one: the
      operator-facing unmerge now fails at the point of applying, after the
      preview has succeeded.

      ⚠️ Worth naming the shape rather than just the bug. That revoke shipped
      with a confident sentence about its callers which nobody checked, and the
      grant list encoded the sentence. It is the same failure as a gate
      allowlist whose reasons read as verified — a claim about CALLERS is a fact
      about the call sites, not about the function holding it, and this project
      already has that lesson on record.

      ## 2. `op.scope_user()` — the sentinel set, defined once

      `op.current_scope()` and `op.blocked_pair()` each decided independently
      what counts as "no user", and the second was the **hand-written negation**
      of the first:

          current_scope:  IF scope = 'anonymous' THEN RETURN NULL
                          IF scope IS NULL OR scope = '' OR scope = 'unset' THEN RAISE
          blocked_pair:   IF scope IS NOT NULL AND scope <> '' AND scope <> 'unset'
                            AND scope <> 'anonymous' THEN …

      Two copies that must agree forever, one of them inverted by hand. A third
      consumer that forgets `<> 'anonymous'` would compare a uuid against the
      literal and either cast-error or, worse, treat an anonymous session as a
      scoped user.

      So `op.scope_user()` answers "which user, or none" with no opinion about
      whether none is acceptable, and the two existing functions become its
      consumers. `op.current_scope()` keeps the RAISE — the refusal is the
      guarantee and must stay where the policies call it.

      ⚠️ It also fixes a guard that silently did not guard: with a NULL
      argument, `a <> scope` was NULL and `NULL AND true` is NULL, so the `IF`
      never fired. Comparing against a `uuid` makes that explicit.

      ## 3. What the pair guard does and does not defend — corrected

      `20261021140000`'s moduledoc claimed:

      > a compromised runtime role can then only ask about pairs it belongs to

      **False as built, and the mechanism is still right.** Both non-user scopes
      fall through by construction, and they have to: the public profile read
      asks this question with no viewer, so refusing when unscoped would turn a
      privacy check into a 5xx on exactly those paths. But `SET LOCAL
      app.current_user_id = 'anonymous'` needs no privilege, so a compromised
      runtime role can declare itself anonymous and enumerate the whole block
      graph regardless.

      The honest claim, which replaces it:

      > A **user-scoped** path can only ask about pairs that user belongs to. An
      > anonymous or unscoped path can ask about any pair, because the public
      > profile read requires it. So this guard catches a scoped caller asking a
      > question that is not theirs; it is **not** a defence against a
      > compromised runtime role, which can simply declare itself anonymous.

      ⚠️ Closing the residual exposure is possible but belongs above the
      database: the public-profile path knows which profile is being viewed, so
      it could pass that owner as one argument and the guard would apply to
      anonymous callers too. An application change, recorded rather than
      attempted here.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    # ── 1. the grant the admin API actually needs ───────────────────────────
    execute("GRANT EXECUTE ON FUNCTION op.placement_owners_for_edition(uuid) TO stacks_app")

    # ── 2. one definition of the sentinel set ───────────────────────────────
    execute("""
    CREATE OR REPLACE FUNCTION op.scope_user() RETURNS uuid
      LANGUAGE plpgsql
      STABLE
    AS $$
    DECLARE
      scope text := current_setting('app.current_user_id', true);
    BEGIN
      -- "No user", for any of the four reasons, with no opinion about whether
      -- that is acceptable. The caller decides: op.current_scope() refuses,
      -- op.blocked_pair() permits.
      IF scope IS NULL OR scope = '' OR scope = 'unset' OR scope = 'anonymous' THEN
        RETURN NULL;
      END IF;

      RETURN scope::uuid;
    END
    $$
    """)

    execute("GRANT EXECUTE ON FUNCTION op.scope_user() TO PUBLIC")

    # ── 3. blocked_pair asks rather than re-deriving ────────────────────────
    execute("""
    CREATE OR REPLACE FUNCTION op.blocked_pair(a uuid, b uuid) RETURNS boolean
      LANGUAGE plpgsql
      STABLE
      SECURITY DEFINER
      SET search_path = op, pg_temp
    AS $$
    DECLARE
      asker uuid := op.scope_user();
    BEGIN
      -- Refuse only when a real user is asking about two other people. A NULL
      -- asker is the public profile path and must keep working; see the
      -- moduledoc for what this therefore does NOT defend against.
      IF asker IS NOT NULL AND a IS DISTINCT FROM asker AND b IS DISTINCT FROM asker THEN
        RAISE EXCEPTION
          'blocked_pair asked about two users, neither of whom is the scoped user'
          USING ERRCODE = '42501',
                HINT = 'pass the viewer as one of the two arguments';
      END IF;

      RETURN EXISTS (
        SELECT 1 FROM op.user_blocks
         WHERE (blocker_id = a AND blocked_id = b)
            OR (blocker_id = b AND blocked_id = a)
      );
    END
    $$
    """)

    execute("ALTER FUNCTION op.blocked_pair(uuid, uuid) OWNER TO rls_reader")
    execute("REVOKE ALL ON FUNCTION op.blocked_pair(uuid, uuid) FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION op.blocked_pair(uuid, uuid) TO stacks_app")

    # ⚠️ `op.current_scope()` now reads the value through the same function, so
    # the sentinel set has exactly one definition. The RAISE stays HERE, not in
    # `scope_user()`, because this is what the policies call and the refusal is
    # the guarantee the whole design rests on.
    execute("""
    CREATE OR REPLACE FUNCTION op.current_scope() RETURNS uuid
      LANGUAGE plpgsql
      STABLE
    AS $$
    DECLARE
      raw text := current_setting('app.current_user_id', true);
      resolved uuid := op.scope_user();
    BEGIN
      -- NULL from scope_user() has two causes and they need opposite answers:
      -- a DELIBERATE anonymous scope is a reader with no account and returns
      -- NULL, so only the public policy arms admit rows; anything else is a
      -- path that forgot to say which user it acts for, and refuses.
      IF resolved IS NULL AND raw IS DISTINCT FROM 'anonymous' THEN
        RAISE EXCEPTION
          'query on a row-level-secured table with no request scope set'
          USING ERRCODE = '42501',
                HINT = 'wrap the query in Stacks.Scope.with_user/2 or Stacks.Scope.anonymous/1, or declare the worker scope';
      END IF;

      RETURN resolved;
    END
    $$
    """)

    execute("GRANT EXECUTE ON FUNCTION op.current_scope() TO PUBLIC")
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("REVOKE EXECUTE ON FUNCTION op.placement_owners_for_edition(uuid) FROM stacks_app")

    # Back to each function deciding for itself, which is the duplication this
    # migration removed. Verbatim from the two preceding migrations.
    execute("""
    CREATE OR REPLACE FUNCTION op.current_scope() RETURNS uuid
      LANGUAGE plpgsql
      STABLE
    AS $$
    DECLARE
      scope text := current_setting('app.current_user_id', true);
    BEGIN
      IF scope = 'anonymous' THEN
        RETURN NULL;
      END IF;

      IF scope IS NULL OR scope = '' OR scope = 'unset' THEN
        RAISE EXCEPTION
          'query on a row-level-secured table with no request scope set'
          USING ERRCODE = '42501',
                HINT = 'wrap the query in Stacks.Scope.with_user/2 or Stacks.Scope.anonymous/1, or declare the worker scope';
      END IF;

      RETURN scope::uuid;
    END
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION op.blocked_pair(a uuid, b uuid) RETURNS boolean
      LANGUAGE plpgsql
      STABLE
      SECURITY DEFINER
      SET search_path = op, pg_temp
    AS $$
    DECLARE
      scope text := current_setting('app.current_user_id', true);
    BEGIN
      IF scope IS NOT NULL AND scope <> '' AND scope <> 'unset' AND scope <> 'anonymous' THEN
        IF a <> scope::uuid AND b <> scope::uuid THEN
          RAISE EXCEPTION
            'blocked_pair asked about two users, neither of whom is the scoped user'
            USING ERRCODE = '42501',
                  HINT = 'pass the viewer as one of the two arguments';
        END IF;
      END IF;

      RETURN EXISTS (
        SELECT 1 FROM op.user_blocks
         WHERE (blocker_id = a AND blocked_id = b)
            OR (blocker_id = b AND blocked_id = a)
      );
    END
    $$
    """)

    execute("DROP FUNCTION IF EXISTS op.scope_user()")
  end
end
