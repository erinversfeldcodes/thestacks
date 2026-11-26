defmodule Stacks.Worker do
  @moduledoc """
      `use Stacks.Worker, scope: :user | :system, …` — `Oban.Worker` plus a
      mandatory declaration of which rows this job is allowed to see.

      Four `op` tables carry row-level security, and their policies refuse any
      query with no request scope set. A worker therefore has to decide, once,
      whether it acts **for a user** (and must scope to them) or **across the
      system** (and must not touch those tables). Omitting `:scope` is a
      **compile error**, which is the point: the question cannot be left
      unanswered by someone who did not know to ask it.

      ## Why a compile error and not a test

      ⛔ Because the test suite cannot see this class of mistake at all. The
      test environment connects as `postgres`, which is `rolsuper = true`, and
      **superusers bypass row-level security entirely** — so a worker that
      queries a secured table with no scope passes every test and fails only on
      a deployed stack, where the application connects as the least-privilege
      role. A green local run is not evidence here, so the enforcement has to
      sit somewhere a green run cannot paper over.

      ## What this does NOT do, and why

      ⚠️ It does not wrap `perform/1` in the scope automatically, though an
      earlier plan said it would. That plan was written before the mechanism was
      measured, and automatic wrapping would reintroduce two bugs the
      measurements found: a `Repo.rollback/1` inside a nested transaction aborts
      the outer one and **discards the value rolled back with**, so a job using
      rollback for control flow would silently return `:rollback` instead of its
      reason; and a declared `unique_constraint` violation inside an explicit
      transaction returns `{:error, :rollback}` rather than `{:error,
      changeset}`. A macro cannot tell which jobs are affected, so it would
      break some of them invisibly.

      So the scope is established explicitly — `Stacks.Scope.with_user/2` where
      the job owns no transaction, `set!/1` or `multi_step/2` where it does —
      and this declaration is what makes "did anyone decide?" a fact on disk
      rather than a question for a reviewer.

      ⚠️ The `user_id` assertion went the same way for a duller reason: this
      macro receives the `use` options and nothing else, so it cannot see the
      `perform/1` head where the args pattern lives. The gate can, and does.

      ## The declaration

        * `scope: :user` — acts for one user and scopes to them. Its `args`
          must carry a `user_id`, because a job declaring `:user` with no user
          to scope to is a contradiction that would otherwise surface as a
          `42501` at three in the morning.
        * `scope: :system` — acts across users and touches **no**
          row-level-secured table.

      ⚠️ **Both claims are checked by `scripts/check-rls-scope.sh`, not by this
      macro**, and the distinction is not pedantry: a macro sees only the `use`
      options, so it cannot tell whether `perform/1` names a user or whether the
      module touches a secured table. What the macro can do is refuse to compile
      without a declaration; what the gate can do is test whether the
      declaration is true. Neither covers the other.

      ⛔ An earlier plan had this macro assert the `user_id` and wrap `perform/1`
      itself. Both were dropped for measured reasons — see below — and the doc
      that still described them was wrong for a day, which is exactly the shape
      of staleness this project keeps finding in its own documentation.
  """

  @valid_scopes [:user, :system]

  defmacro __using__(opts) do
    {scope, oban_opts} = Keyword.pop(opts, :scope)

    unless scope in @valid_scopes do
      raise CompileError,
        description: """
        #{inspect(__CALLER__.module)} must declare its row-level-security scope:

            use Stacks.Worker, scope: :user, queue: :default, max_attempts: 3
            use Stacks.Worker, scope: :system, queue: :default, max_attempts: 3

        `:user` means the job acts for one user and scopes to them — its args
        must carry a "user_id". `:system` means it acts across users and touches
        none of the row-level-secured tables (bookshelves, bookshelf_placements,
        user_blocks, visibility_grants).

        Got: #{inspect(scope)}

        This is a compile error rather than a test because the test role is a
        superuser and bypasses row-level security entirely — an unscoped query
        passes every test and fails only on a deployed stack.
        """
    end

    quote do
      use Oban.Worker, unquote(oban_opts)

      @doc false
      def __rls_scope__, do: unquote(scope)
    end
  end

  @doc """
      Every worker module, with the scope it declared.

      ⚠️ Its caller is `Stacks.WorkerScopeDeclarationTest`, and that test exists
      because this function asserts something `scripts/check-rls-scope.sh`
      structurally cannot: the gate reads source TEXT, so it would keep passing
      if this macro silently stopped emitting `__rls_scope__/0`. This reports
      the runtime fact. (An earlier version of this docstring claimed the gate
      was a caller. It is a shell script that greps; it calls nothing.)
  """
  @spec declared_scopes() :: [{module(), :user | :system}]
  def declared_scopes do
    {:ok, modules} = :application.get_key(:core, :modules)

    for module <- modules,
        function_exported?(module, :__rls_scope__, 0) or Code.ensure_loaded?(module),
        function_exported?(module, :__rls_scope__, 0),
        do: {module, module.__rls_scope__()}
  end
end
