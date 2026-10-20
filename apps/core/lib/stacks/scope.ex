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

  # ⛔ Nesting is a property of the CALL STACK, so it is tracked per process
  # rather than by reading the scope back from the connection — and that
  # distinction is not academic. `SET LOCAL` reverts when its transaction ends,
  # but under ExUnit's sandbox the enclosing transaction is the sandbox's and
  # lasts for the whole test, so the connection still reports the previous
  # scope after a call has returned. Asking the connection therefore reports
  # two sequential calls for different users as an illegal re-scope, which is
  # true of nothing: a test exercising two users in turn is the ordinary case,
  # and so is a worker iterating over them.
  @nesting_key :stacks_rls_scope

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
    case Process.get(@nesting_key) do
      nil ->
        Process.put(@nesting_key, user_id)

        try do
          {:ok, result} = Repo.transaction(fn -> set_and_run(user_id, fun) end)
          result
        after
          Process.delete(@nesting_key)
        end

      ^user_id ->
        # Already scoped to this same user by an enclosing call. Running `fun`
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

  @doc """
      Sets the scope inside a transaction the caller already owns.

      ⛔ **Use this, not `with_user/2`, in any function that opens its own
      `Repo.transaction` or builds an `Ecto.Multi` — and the reason is a
      measured Ecto behaviour, not a preference.** `with_user/2` opens a
      transaction; if the function it wraps then opens its own, that becomes a
      SAVEPOINT, and a `Repo.rollback/1` inside a nested transaction aborts the
      OUTER one and returns `{:error, :rollback}` — **discarding the value the
      inner code rolled back with**. A context using rollback for control flow
      (`{:error, :reading_pile_full}`) silently loses its reason and the caller
      sees `:rollback` instead. Four tests caught exactly that.

      ⚠️ Raises outside a transaction rather than returning an error, because
      the alternative is worse than either: `set_config(..., true)` outside a
      transaction is a no-op that reports success, so the scope would appear set
      and the next query on an RLS table would refuse with `42501` somewhere
      that does not name this as the cause.
  """
  @spec set!(Ecto.UUID.t()) :: :ok
  def set!(user_id) when is_binary(user_id) do
    unless Repo.in_transaction?() do
      raise ArgumentError,
            "Stacks.Scope.set!/1 was called outside a transaction, where the setting is a " <>
              "no-op that reports success. Use Stacks.Scope.with_user/2, which opens one."
    end

    Repo.query!("SELECT set_config('app.current_user_id', $1, true)", [user_id])

    :ok
  end

  @doc """
      An `Ecto.Multi` step that sets the scope, for contexts built as a Multi.

      Named `:rls_scope` and intended as the FIRST step: a Multi runs its steps
      in order inside one transaction, so any step touching a row-level-secured
      table before this one would refuse.
  """
  @spec multi_step(Ecto.Multi.t(), Ecto.UUID.t()) :: Ecto.Multi.t()
  def multi_step(multi, user_id) when is_binary(user_id) do
    Ecto.Multi.run(multi, :rls_scope, fn repo, _changes ->
      repo.query!("SELECT set_config('app.current_user_id', $1, true)", [user_id])
      {:ok, user_id}
    end)
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
