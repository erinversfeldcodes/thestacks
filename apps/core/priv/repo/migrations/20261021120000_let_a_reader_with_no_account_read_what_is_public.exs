defmodule Core.Repo.Migrations.LetAReaderWithNoAccountReadWhatIsPublic do
  @moduledoc """
      `op.current_scope()` gains a fourth state: a scope deliberately set to
      **no user**, which returns NULL instead of raising.

      ⛔ **Why: every anonymous read of a secured table was refused, and that is
      most of the public site.** The refusal was built to catch "somebody forgot
      to scope". It cannot tell that apart from "there is genuinely nobody here",
      and so it also refused the catalogue, the marketplace listing pages,
      search, the public profile, the blog archive and the public transparency
      page — all of which are reachable without an account and all of which read
      `op.bookshelves` or `op.bookshelf_placements`.

      Measured as the runtime role, with no scope set, before this change:

          SELECT count(*) FROM op.bookshelves WHERE visibility = 'platform'
            → ERROR 42501 query on a row-level-secured table with no request scope set

      ⚠️ **Writing the public arm first does not help, and that is the part worth
      recording.** Postgres combines permissive policies with `OR` and gives no
      short-circuit guarantee, so a row satisfying `visibility = 'platform'`
      still evaluates the owner arm, which calls this function, which raises.
      Measured both orderings; both raise. There is no query shape that reads
      public rows without passing through here.

      ⚠️ The refusal being order-independent is the *right* property — it is what
      makes the guarantee deterministic rather than dependent on row content, and
      it was verified deliberately. The gap was never the refusal. It was that
      the design had no way to say "no user, on purpose".

      ## Why a sentinel and not simply allowing an unset scope through

      Returning NULL for an unset scope would have made the two cases
      indistinguishable again and silently un-built the whole guarantee: a
      forgotten scope would read as an anonymous visitor and quietly return the
      public subset instead of refusing. So "nobody is here" has to be **stated**,
      and the caller states it: `Stacks.Scope.anonymous/1` sets this value.

      `'anonymous'` joins `''` and `'unset'` as a reserved non-uuid value, and is
      distinguished from them by intent rather than by accident — those two mean
      "never scoped" and "scoped and reverted", both of which are mistakes on a
      request path.

      ## What an anonymous reader can then see, exactly

      NULL propagates: `user_id = NULL` is NULL, which a policy treats as not
      satisfied, so the owner arm admits nothing. The remaining permissive arms
      are the ones that say a row is public, so an anonymous reader sees exactly
      those and nothing else:

        * `op.bookshelves` — `visibility = 'platform'`, plus the
          `looking_for_home` arm whose width is accepted elsewhere.
        * `op.bookshelf_placements` — platform-visible placements and active
          marketplace listings.
        * `op.user_blocks`, `op.visibility_grants` — nothing. Neither carries a
          public arm, which is correct: both are private by nature, and an
          anonymous reader asking either question gets an empty result rather
          than an error.

      ⛔ So this widens nothing. Every row an anonymous reader can now reach was
      already reachable by any signed-in reader through the same policy arm; the
      only change is that asking without an account returns rows instead of an
      error.
  """

  use Ecto.Migration

  @anonymous "anonymous"

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION op.current_scope() RETURNS uuid
      LANGUAGE plpgsql
      STABLE
    AS $$
    DECLARE
      scope text := current_setting('app.current_user_id', true);
    BEGIN
      -- A reader with no account, said deliberately. NULL here means the owner
      -- arm of every policy is not satisfied, so only the public arms admit
      -- rows. It is a different fact from the three below and must not be
      -- folded in with them.
      IF scope = '#{@anonymous}' THEN
        RETURN NULL;
      END IF;

      -- ⚠️ Three states, one answer. NULL is a connection that has never been
      -- scoped; the empty string is one that was scoped and whose transaction
      -- ended, because SET LOCAL reverts to the parameter's default and an
      -- already-seen custom parameter defaults to ''; 'unset' is the role
      -- default where a superuser was available to set one. None of them is a
      -- user, and none of them is a deliberate statement that there is no user
      -- — each is a path that forgot to say which. Reading any of them as a
      -- user would set a scope matching no row; reading any of them as
      -- anonymous would silently downgrade a signed-in request to the public
      -- subset, which is the same bug wearing a success message.
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

    execute("GRANT EXECUTE ON FUNCTION op.current_scope() TO PUBLIC")
  end

  def down do
    # Back to refusing every anonymous read. ⚠️ This re-breaks the public
    # surface; it is the previous definition verbatim and is here for
    # reversibility, not because it is a state worth returning to.
    execute("""
    CREATE OR REPLACE FUNCTION op.current_scope() RETURNS uuid
      LANGUAGE plpgsql
      STABLE
    AS $$
    DECLARE
      scope text := current_setting('app.current_user_id', true);
    BEGIN
      IF scope IS NULL OR scope = '' OR scope = 'unset' THEN
        RAISE EXCEPTION
          'query on a row-level-secured table with no request scope set'
          USING ERRCODE = '42501',
                HINT = 'wrap the query in Stacks.Scope.with_user/2, or declare the worker scope';
      END IF;

      RETURN scope::uuid;
    END
    $$
    """)
  end
end
