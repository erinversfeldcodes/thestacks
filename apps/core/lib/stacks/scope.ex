defmodule Stacks.Scope do
  @moduledoc """
      Establishes the per-request row-level-security scope: the user whose rows
      the database will allow this piece of work to see.

      Four `op` tables carry row-level security — `bookshelves`,
      `bookshelf_placements`, `user_blocks`, `visibility_grants` — and their
      policies compare each row against `op.current_scope()`, which reads the
      `app.current_user_id` session variable and RAISES when it is unset. So
      every read or write of those tables must happen inside one of the wrappers
      here — `with_user/2`, `set!/1`, `multi_step/2`, or `anonymous/1` for a
      reader with no account — or it fails with `42501` rather than quietly
      returning nothing. See "Four states, not two" below: a deliberately
      anonymous scope is the one case that is neither a user nor a refusal.

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

      ## Four states, not two

      ⚠️ `op.current_scope()` distinguishes four cases, and the fourth was added
      after the first three shipped:

        * **a user id** — the ordinary scoped read.
        * **never set** / **`''`** / **`'unset'`** — a forgotten scope. RAISES
          `42501`, because the overwhelmingly likely cause is a path that did
          not say which user it acts for. (`''` is what `SET LOCAL` reverts to
          once a custom parameter has been seen; `'unset'` a role default where
          a superuser was available to set one.)
        * **`'anonymous'`** — deliberately no user, set only by `anonymous/1`.
          Returns NULL, so the owner arm of every policy is unsatisfied and the
          reader sees exactly the rows whose policies say they are public.

      ⛔ The fourth state is not a relaxation. Allowing an *unset* scope through
      would have made "forgot to scope" indistinguishable from "no viewer", so a
      missed scope would quietly serve the public subset instead of refusing —
      the same bug wearing a success message. "Nobody is here" has to be stated
      by the caller, and the refusal for the other three is unchanged.

      ⚠️ It exists because without it every anonymous read of these tables was
      refused — the catalogue, search, the marketplace listing pages, a public
      profile, the blog archive and the public transparency page. Measured: an
      unscoped read raises even when the query's own predicate targets only a
      public policy arm, because Postgres gives no short-circuit guarantee
      across OR'd permissive policies, so no query shape avoided it.

      ## Every query is scoped to somebody or to nobody — there is no system escape

      There is deliberately no `with_system_scope/1` and no sentinel value that
      means "see everything" — note that `'anonymous'` is the opposite of that:
      it sees LESS than any user, not more. Background work that acts for a user
      scopes to that user; background work that acts across users iterates and
      scopes to each in turn, or asks one of the narrow `op.*` definer functions
      for the single cross-user fact it needs. The two reasons are recorded in
      the ADR: a sentinel expressed as an `OR` term in the policy turns every
      query on these tables into a sequential scan (measured on 50,000 rows,
      *even when scoped to a real user*), and a role exempt from the policies
      would be a standing credential that can read every user's rows.

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

  # ⚠️ Must match the reserved value `op.current_scope()` answers with NULL.
  # Not a uuid, so it can never collide with a real user id.
  @anonymous "anonymous"

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
  def with_user(nil, fun) when is_function(fun, 0) do
    # ⚠️ An absent user id runs UNSCOPED rather than raising here, and that is
    # safe for a precise reason: the database still refuses. A context function
    # can legitimately be called with a nil user — its changeset validation is
    # what should report that, and a `validate_required` failure never reaches
    # the database at all. If such a call did reach a row-level-secured table,
    # `op.current_scope()` raises `42501`, which is the designed answer to an
    # unscoped query.
    #
    # ⛔ What this must NOT become is a way to opt out. It runs `fun` with no
    # scope set, so every RLS query inside it fails; it buys a clean changeset
    # error for a nil argument, nothing more.
    fun.()
  end

  def with_user(user_id, fun) when is_binary(user_id) and is_function(fun, 0) do
    user_id = normalise!(user_id)

    case Process.get(@nesting_key) do
      nil ->
        Process.put(@nesting_key, user_id)

        # ⚠️ Captured BEFORE opening our own transaction. Asked inside it,
        # `in_transaction?/0` is true by construction — we just opened one —
        # so the restore would always run and the per-request cost would come
        # straight back.
        restore? = must_restore?()

        try do
          {:ok, result} = Repo.transaction(fn -> set_and_run(user_id, fun, restore?) end)
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

      ⛔ Returns `:anonymous` — an atom, not a uuid and not `nil` — when the
      scope is deliberately set to no user. Three outcomes rather than two,
      because "no user on purpose" and "no scope at all" are different facts
      and collapsing them is what this state exists to prevent. A caller that
      only needs to know whether a real user is scoped should match on a binary
      rather than on `!= nil`, which would read anonymous as a user.
  """
  @spec current() :: Ecto.UUID.t() | :anonymous | nil
  def current do
    case Repo.query("SELECT current_setting('app.current_user_id', true)", []) do
      {:ok, %{rows: [[@anonymous]]}} -> :anonymous
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

      ⚠️ **NO CALLERS TODAY.** Nothing outside this module calls it — grep
      `apps/core/lib` and `apps/core/test`. It is kept rather than deleted
      because it is the correct primitive for a function that owns its own
      transaction and does not build a `Multi`, and `multi_step/2` covers only
      the `Multi` half of that case. Treat the absence of callers as a fact to
      check before trusting the moduledoc's four-wrapper summary, not as a
      reason to reach for it.

      ⛔ **Unlike `with_user/2`, this does NOT restore the previous scope, and
      the asymmetry is deliberate: the caller owns the transaction, so the
      caller owns the revert.** `with_user/2` opens its own transaction and
      therefore knows whether a commit will arrive to revert `SET LOCAL`; a
      function using `set!/1` has already opened one and this has no way to
      know when it ends. So a scope set here survives until the caller's
      transaction does — which is correct when that transaction commits, and a
      leak when it is itself a savepoint inside somebody else's. The same holds
      for `multi_step/2`. Neither is live today, checked: `set!/1` has no
      callers, and no `multi_step/2` Multi currently runs inside a transaction
      it did not open.
  """
  @spec set!(Ecto.UUID.t()) :: :ok
  def set!(user_id) when is_binary(user_id) do
    user_id = normalise!(user_id)

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
    user_id = normalise!(user_id)

    Ecto.Multi.run(multi, :rls_scope, fn repo, _changes ->
      repo.query!("SELECT set_config('app.current_user_id', $1, true)", [user_id])
      {:ok, user_id}
    end)
  end

  # ⛔ `is_binary/1` cannot tell a UUID STRING from a raw 16-byte UUID, and both
  # are binaries that reach here in practice: Ecto hands back the string form,
  # while `Ecto.UUID.dump/1` and the seed fixtures produce the 16-byte form.
  #
  # Passing the raw form through to `set_config` fails at the database with
  # `invalid byte sequence for encoding "UTF8"` — which is how this was found —
  # and that is the LUCKY case. A 16-byte UUID whose bytes happen to be valid
  # UTF-8 would be accepted silently and set a scope matching no user, so every
  # query in that operation would return nothing while reporting success.
  #
  # `Ecto.UUID.cast/1` accepts both representations and yields the canonical
  # string, so this is total over what callers actually pass and loud about
  # anything else.
  defp normalise!(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, canonical} ->
        canonical

      :error ->
        raise ArgumentError,
              "the row-level-security scope must be a UUID, got #{inspect(user_id, limit: 8)}. " <>
                "A non-UUID scope would be set without complaint and then match no row, so " <>
                "every query in the operation would quietly return nothing."
    end
  end

  @doc """
      Runs `fun` as a reader with **no account**, which is a different thing
      from running it unscoped.

      ⛔ The distinction is the whole point. An unscoped query is refused,
      because the overwhelmingly likely cause is that somebody forgot to scope
      one. A query made on behalf of nobody is legitimate — it is what the
      catalogue, search, the marketplace listing pages, a public profile, the
      blog archive and the public transparency page all are — and it has to be
      expressible without weakening the refusal.

      So this sets the scope to a reserved value that `op.current_scope()`
      answers with NULL. The owner arm of every policy is then not satisfied
      (`user_id = NULL` is NULL), and the reader sees exactly the rows whose
      policies say they are public: platform-visible shelves and placements,
      and active marketplace listings. Private tables carry no public arm, so
      an anonymous reader asking about blocks or grants gets no rows rather
      than an error.

      ⚠️ This widens nothing. Every row reachable here was already reachable by
      any signed-in reader through the same policy arm.

      ⛔ Use it only where the request genuinely has no viewer. On a path where
      a viewer *may* be present — the `:optional_auth` pipeline — pass the
      viewer to `with_user/2` when there is one and come here only when there
      is not. Calling this with a viewer in hand silently downgrades them to
      the public subset, which looks like a working page with content missing.
  """
  @spec anonymous((-> result)) :: result when result: var
  def anonymous(fun) when is_function(fun, 0) do
    case Process.get(@nesting_key) do
      nil ->
        Process.put(@nesting_key, @anonymous)

        restore? = must_restore?()

        try do
          {:ok, result} = Repo.transaction(fn -> set_and_run(@anonymous, fun, restore?) end)
          result
        after
          Process.delete(@nesting_key)
        end

      @anonymous ->
        fun.()

      other ->
        # ⛔ Refused for the same reason as a re-scope between two users, and it
        # is the more dangerous direction: dropping to anonymous inside a
        # scoped operation returns the PUBLIC subset of someone's own data,
        # which is a wrong answer rather than an error, and reads as a page
        # that merely has less on it.
        raise ArgumentError,
              "cannot drop from #{inspect(other)} to an anonymous scope inside one operation: " <>
                "a request either has a viewer or it does not, and narrowing to the public " <>
                "subset mid-request silently hides rows the viewer is entitled to"
    end
  end

  @doc """
      Runs `fun` scoped to `viewer_id`, or anonymously when it is `nil`.

      The shape the `:optional_auth` pipeline needs: those routes serve both a
      signed-in reader and one with no account, and the two differ only in
      which scope is correct. Written once here so no controller has to
      remember that `nil` means `anonymous/1` and not `with_user/2` — passing a
      nil viewer to `with_user/2` runs UNSCOPED and is refused by the database.
  """
  @spec for_viewer(Ecto.UUID.t() | nil, (-> result)) :: result when result: var
  def for_viewer(nil, fun) when is_function(fun, 0), do: anonymous(fun)

  def for_viewer(viewer_id, fun) when is_binary(viewer_id) and is_function(fun, 0),
    do: with_user(viewer_id, fun)

  defp set_and_run(user_id, fun, restore?) do
    # ⚠️ Parameterised through `$1` rather than interpolated. `SET LOCAL` does
    # not accept a bind parameter, so this uses `set_config/3`, which does —
    # and which is therefore the only form here that cannot be made to carry
    # SQL by a crafted id. The third argument `true` is what makes it LOCAL.
    #
    # ⛔ The previous value is captured and RESTORED, rather than trusting the
    # enclosing transaction to revert it. `SET LOCAL` reverts when the
    # transaction that issued it ends — but under the test sandbox the
    # connection is held open inside one long transaction, so this block is a
    # SAVEPOINT, and **releasing a savepoint does not revert a SET LOCAL made
    # inside it**. Measured: after an inner scope ended, the setting still read
    # as the user that block had scoped to, while the same sequence against a
    # real committed transaction read as empty.
    #
    # That leak is why a scope could outlive its own block and be seen by an
    # unrelated later query — which turned a legitimate `op.blocked_pair/2`
    # call into a refusal in three tests, and would have made any scope-reading
    # guard behave differently in the suite than in production. Restoring
    # explicitly makes the two environments agree, and is a no-op in the one
    # where the transaction would have done it anyway.
    # ⛔ The condition is "will a COMMIT intervene to revert this", and nothing
    # else. An earlier version keyed on the connection pool, on the premise that
    # a real connection always commits — and that premise is FALSE whenever this
    # function is called inside a transaction it did not open, because then our
    # `Repo.transaction` is a savepoint and releasing a savepoint does not
    # revert a `SET LOCAL` made inside it.
    #
    # ⛔ The consequence was the worst available shape: the suite took the
    # restoring branch and PRODUCTION took the leaking one, so no test could
    # observe production's behaviour. It is reachable on the deploy path —
    # `DataCorrection.apply_plan/4` opens a transaction and the unmerge
    # correction then calls `with_user/2` once per owner inside it, leaving the
    # outer transaction scoped to whichever owner was iterated last with nothing
    # in the process state recording it.
    #
    # ⚠️ Both terms are load-bearing and the first is NOT redundant. Measured:
    # `Repo.in_transaction?/0` is **false** at the top of a sandboxed test,
    # because the sandbox holds its transaction at the connection level, outside
    # Ecto's per-process tracking — so `in_transaction?/0` alone would skip the
    # restore in the one environment where nothing else ends the scope. Pinned
    # by `scope_transaction_probe_test.exs`, which also says what to simplify if
    # that ever changes.
    #
    # ⚠️ At a genuine request boundary both terms are false, so the restore does
    # not run and costs nothing — which is what keeps the per-request query
    # bounds where they were.
    #
    # `set_and_run/3` is reached only at the OUTERMOST scope — a nested
    # same-user call runs `fun` directly and a different user raises — so
    # restoring to the unset value is right, and needs no read of the previous
    # one.
    # ⛔ THE RESTORE RUNS ON THE SUCCESS PATH ONLY, and there is deliberately no
    # `try`/`after` around it.
    #
    # It was an `after` clause, which made it run on the failure path too — and
    # on that path it CANNOT succeed: once a statement aborts a Postgres
    # transaction, every later statement fails with "current transaction is
    # aborted", so the restore raised and its exception REPLACED the one that
    # actually failed. MEASURED while building the least-privilege test harness:
    # a policy refusal inside `fun` was undiagnosable through two different
    # nestings, with the stack frame blaming this helper rather than the query.
    #
    # ⚖️ The first fix was a `rescue` inside the `after`, and a reviewer was
    # right that it treated the symptom. The asymmetry recorded above is the
    # whole argument: `RELEASE SAVEPOINT` KEEPS a `SET LOCAL` while
    # `ROLLBACK TO SAVEPOINT` reverts it — so the failure path never needed a
    # restore at all, and the `after` was covering a case that needs no cover.
    # Removing it means the real error from `fun` propagates untouched.
    #
    # ⚠️ And the restore is now allowed to raise, which is what you want: on the
    # success path the realistic failure is `fun` having returned normally after
    # swallowing a Postgrex error, and that is precisely the case worth hearing
    # about. It was silent before.
    if restore? do
      Repo.query!("SELECT set_config('app.current_user_id', $1, true)", [user_id])
      result = fun.()
      Repo.query!("SELECT set_config('app.current_user_id', '', true)")
      result
    else
      Repo.query!("SELECT set_config('app.current_user_id', $1, true)", [user_id])
      fun.()
    end
  end

  @doc """
      Whether a scope set now must be restored by hand when the block ends.

      ⛔ Takes its inputs so the DECISION can be tested, which the behaviour
      cannot be. Under the sandbox `sandboxed?/0` is always true, so
      `must_restore?/0` short-circuits and an end-to-end assertion passes under
      the old pool-keyed implementation too — the suite exercises the restoring
      branch and production exercised the leaking one, which is the very
      asymmetry this condition was changed to remove. The truth table is
      therefore the only part of it a test in the suite can pin, and the
      `{false, true}` row IS the production leak case.

      ⚠️ `false, false` is the ordinary request boundary: the transaction this
      opens is the outermost one, its commit reverts `SET LOCAL`, and an extra
      statement would be pure cost on every scoped read.
  """
  @spec must_restore?(boolean(), boolean()) :: boolean()
  def must_restore?(sandboxed?, in_transaction?), do: sandboxed? or in_transaction?

  # The two facts `must_restore?/2` decides from, as data.
  #
  # ⛔ Separated from the decision because the decision was never the bug. The
  # old condition did not get `or` wrong — it **omitted the second argument**,
  # and a truth table over `/2` cannot see that: reverting the combiner below
  # to `sandboxed?()` alone leaves all four rows green, because `/2` is
  # untouched, and leaves the end-to-end cases green too, because `sandboxed?/0`
  # is always true in the suite.
  #
  # ⚠️ PRIVATE, and it was briefly public so a test could call it. That bought
  # nothing: the planted regression left those tests green as well, because
  # in-suite `sandboxed?()` is true and so `sandboxed?() or anything` IS
  # `sandboxed?()` for every second term. The composition is unobservable here
  # by construction, so it is pinned by a source-reading assertion in
  # `scope_transaction_probe_test.exs` — which needs this function's NAME, not
  # its visibility. Making an internal detail public to buy coverage that does
  # not exist is the trade this reverses.
  @spec restore_inputs() :: {boolean(), boolean()}
  defp restore_inputs, do: {sandboxed?(), Repo.in_transaction?()}

  defp must_restore? do
    {sandboxed?, in_transaction?} = restore_inputs()
    must_restore?(sandboxed?, in_transaction?)
  end

  defp sandboxed?, do: Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox
end
