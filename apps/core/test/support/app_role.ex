defmodule Core.AppRole do
  @moduledoc """
  Run a block as the least-privilege runtime role, so row-level security
  actually applies inside an ordinary sandboxed test.

  ## Why this exists

  ⛔ Every test in this suite connects as `postgres`, a SUPERUSER, which
  **bypasses row-level security entirely**. So the policies that protect user
  data were unenforced in `MIX_ENV=test` and the suite could not tell. That gap
  shipped a 500 to a deployed stack: seven placement lookups and three
  `get_or_create_bookshelf/2` calls ran BEFORE the `Ecto.Multi` whose first step
  set the scope, so they queried secured tables unscoped. `POST
  /api/bookshelves/library/placements` returned HTTP 500 with
  `ERROR 42501 query on a row-level-secured table with no request scope set`.

  ⚠️ Every local instrument was GREEN throughout: 4150 unit tests, every Elixir
  gate, and `check-rls-scope.sh` itself — which asks whether a module
  establishes a scope ANYWHERE, not whether every query in it is covered.
  `shelving.ex` passed because it scopes in twenty other places. The deployed
  drive was the only instrument that could see it.

  ## Why `SET LOCAL ROLE` rather than a second repo

  The obvious approach is a second `Repo` configured as `stacks_app`, and it
  does not work under the sandbox: each test runs inside an uncommitted
  transaction, so a second connection cannot see the fixtures the first one
  wrote. Working around that means an unsandboxed lane with real commits and
  manual cleanup — slow, and a cleanup bug there corrupts the shared test
  database.

  ⚖️ `SET LOCAL ROLE` dissolves that. It changes `current_user` for the rest of
  the transaction, so policies apply AND the sandbox's own fixture data stays
  visible, on the same connection. MEASURED against `stacks_test`:

      BEGIN;
      -- current_user=postgres, rolsuper=true
      SET LOCAL ROLE stacks_app;
      -- current_user=stacks_app, rolsuper=false
      SELECT count(*) FROM op.bookshelves;
      -- ERROR: query on a row-level-secured table with no request scope set

  That error is this project's own `current_scope()` raise, which is the proof
  that policies are being evaluated rather than skipped.

  ## The anti-vacuity problem this helper has to solve

  ⛔ If `SET ROLE` silently did nothing, every assertion inside the block would
  run as a superuser and PASS — a test layer that reports enforcement while
  measuring none. That is the defect class this whole area keeps producing, so
  the switch is VERIFIED rather than assumed: the helper reads back
  `current_user` and `rolsuper` and raises if either says it is still
  privileged. A caller cannot opt out of that check.
  """

  alias Ecto.Adapters.SQL

  @app_role "stacks_app"

  @doc """
  Run `fun` with the connection's role dropped to `#{@app_role}`.

  Must be called inside a transaction — the sandbox provides one. Raises if the
  role did not actually change, so a silently-ignored `SET ROLE` cannot produce
  a green run.

  The role is restored with `RESET ROLE` afterwards, including on error, so
  fixtures created after the block are not accidentally written as the
  least-privilege role.
  """
  def as_app_role(repo \\ Core.Repo, fun) when is_function(fun, 0) do
    SQL.query!(repo, "SET LOCAL ROLE #{@app_role}", [])
    assert_role_dropped!(repo)

    try do
      fun.()
    after
      # ⛔ TOLERANT, and not for tidiness. `RESET ROLE` raising here would mask
      # the error that actually failed the block: once any statement errors,
      # Postgres aborts the transaction and every later statement — including
      # this reset — fails with "current transaction is aborted". An `after`
      # clause that raises replaces the real diagnosis with its own, and that
      # cost a round of misdiagnosis: a genuine policy refusal surfaced only as
      # "transaction rolling back" from inside this helper's stack frame.
      #
      # ⚠️ Swallowing it is safe because `SET LOCAL ROLE` reverts at transaction
      # end regardless, and the sandbox ends the transaction after every test.
      # The reset is a convenience for fixtures created later in the SAME test,
      # not a correctness requirement.
      try do
        SQL.query!(repo, "RESET ROLE", [])
      rescue
        _ -> :ok
      end
    end
  end

  @doc """
  True when the suite's own connection is a superuser.

  Used by the tests that document the boundary, so "this suite bypasses RLS" is
  an assertion about the database rather than a claim in a comment.
  """
  def superuser?(repo \\ Core.Repo) do
    %{rows: [[super?]]} =
      SQL.query!(repo, "SELECT rolsuper FROM pg_roles WHERE rolname = current_user", [])

    super?
  end

  defp assert_role_dropped!(repo) do
    %{rows: [[role, super?]]} =
      SQL.query!(
        repo,
        """
        SELECT current_user::text,
               (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)
        """,
        []
      )

    cond do
      role != @app_role ->
        raise """
        SET LOCAL ROLE did not take: current_user is #{inspect(role)}, expected #{inspect(@app_role)}.

        Every assertion inside this block would have run with superuser privileges, which
        BYPASS row-level security — so the block would have reported enforcement while
        measuring none. Refusing rather than running.
        """

      super? ->
        raise """
        current_user is #{inspect(role)} but it is a SUPERUSER, so row-level security is
        still bypassed and this block would measure nothing.

        Check that #{@app_role} has not been granted superuser in this database.
        """

      true ->
        :ok
    end
  end
end
