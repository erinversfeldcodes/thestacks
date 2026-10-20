defmodule Stacks.Scope do
  @moduledoc """
      Establishes the per-request row-level-security scope: the user whose rows
      the database will allow this piece of work to see.

      Four `op` tables carry row-level security — `bookshelves`,
      `bookshelf_placements`, `user_blocks`, `visibility_grants` — and their
      policies compare each row against `op.current_scope()`, which reads the
      `app.current_user_id` session variable and RAISES when it is unset. So
      every read or write of those tables must happen inside one of the wrappers
      here, or it fails with `42501` rather than quietly returning nothing.

      Every alternative to the mechanism below was measured and rejected for a
      reason named at its own site: a session-level `SET` leaks across pooled
      connections, a request-wide transaction would pin a connection for the
      life of an SSE stream, and a sentinel value meaning "see everything"
      turns these tables' every query into a sequential scan.

      ## Why a transaction, and not a plug

      ⛔ `SET LOCAL` outside a transaction emits a WARNING and does nothing —
      measured, not assumed. That is the worst available failure: the code looks
      wired, the setting never takes, and the policy then refuses every query it
      was supposed to permit. So the scope is always set inside an explicit
      transaction, and `with_user/2` is the only thing that sets it.

      ⚠️ A session-level `SET` with a `RESET` afterwards would need no
      transaction, and was rejected because its failure mode is the harm this
      whole mechanism exists to prevent: on a pooled connection a missed reset
      serves one reader another reader's rows, and a `before_send` hook does not
      run on every abnormal exit path.

      ⚠️ A single request-wide transaction opened by a plug was also rejected,
      and the reason is specific to this application rather than general advice:
      `StacksWeb.UploadController` serves `text/event-stream` with a heartbeat
      loop, so a transaction held for the life of a request would pin a database
      connection and an open transaction for the whole duration of every
      progress stream.

      ## Every query is scoped to somebody — there is no system escape

      There is deliberately no `with_system_scope/1` and no sentinel value that
      means "see everything". Background work that acts for a user scopes to
      that user; background work that acts across users iterates and scopes to
      each in turn. The two reasons are recorded in the ADR: a sentinel
      expressed as an `OR` term in the policy turns every query on these tables
      into a sequential scan (measured on 50,000 rows, *even when scoped to a
      real user*), and a role exempt from the policies would be a standing
      credential that can read every user's rows.

      The warehouse is the one exemption, and it is declarative rather than
      coded: `stacks_dbt` and `stacks_readonly` carry their own role-scoped
      `USING (true)` policies, auditable in `pg_policies`.
  """

  alias Core.Repo

  @doc """
      Runs `fun` with the row-level-security scope set to `user_id`.

      Opens a transaction, issues `SET LOCAL app.current_user_id`, and returns
      whatever `fun` returns — unwrapped, so a caller reads the same as it did
      before the scope existed.

      ⚠️ Nests safely. `Repo.transaction/2` inside a transaction becomes a
      savepoint rather than a second transaction, and `SET LOCAL` applies to the
      outermost one, so a context function that scopes and then calls another
      that scopes behaves correctly. The inner call re-asserting the same user
      is a no-op; re-asserting a *different* user is refused below, because that
      is a bug wearing the shape of a nested call.
  """
  @spec with_user(Ecto.UUID.t(), (-> result)) :: result when result: var
  def with_user(user_id, fun) when is_binary(user_id) and is_function(fun, 0) do
    case current() do
      nil ->
        {:ok, result} = Repo.transaction(fn -> set_and_run(user_id, fun) end)
        result

      ^user_id ->
        # Already scoped to this same user by an outer wrapper. Running `fun`
        # directly keeps the transaction depth flat, which matters because an
        # unnecessary savepoint per nested context call is pure overhead.
        fun.()

      other ->
        # ⛔ Not a nesting case — a correctness one. Two different users in one
        # logical operation means something is reading on behalf of the wrong
        # person, and the database would happily serve whichever scope happened
        # to be outermost. Louder here than as a row that should not exist.
        raise ArgumentError,
              "cannot re-scope from #{inspect(other)} to #{inspect(user_id)} inside one " <>
                "operation: the row-level-security scope is per request, and two users in one " <>
                "request means a query is running on behalf of the wrong one"
    end
  end

  @doc """
      The user id the current scope is set to, or `nil` when unscoped.

      Reads the session variable rather than process state on purpose: the
      database is the thing that acts on it, so asking anything else would be
      asking a cache whether the real setting took.

      ⚠️ Returns `nil` both when the variable was never set and when it holds
      the runtime role's `'unset'` default — `SET LOCAL` reverts to that
      default, so after a scoped transaction commits a pooled connection reads
      `'unset'` rather than NULL. Treating one as scoped and the other as not
      is how the policy this replaces became non-deterministic across pooled
      connections.
  """
  @spec current() :: Ecto.UUID.t() | nil
  def current do
    case Repo.query("SELECT current_setting('app.current_user_id', true)", []) do
      {:ok, %{rows: [[value]]}} when value in [nil, "", "unset"] -> nil
      {:ok, %{rows: [[value]]}} -> value
      _ -> nil
    end
  end

  defp set_and_run(user_id, fun) do
    # ⚠️ Parameterised through `$1` rather than interpolated. `SET LOCAL` does
    # not accept a bind parameter, so this uses `set_config/3`, which does —
    # and which is therefore the only form here that cannot be made to carry
    # SQL by a crafted id. The third argument `true` is what makes it LOCAL.
    Repo.query!("SELECT set_config('app.current_user_id', $1, true)", [user_id])

    fun.()
  end
end
