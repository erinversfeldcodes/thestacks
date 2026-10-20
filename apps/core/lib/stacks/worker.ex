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

      ## The declaration

        * `scope: :user` — acts for one user. Its `args` must carry a
          `user_id`, asserted below, because a job declaring `:user` with no
          user to scope to is a contradiction that would otherwise surface as a
          `42501` at three in the morning.
        * `scope: :system` — acts across users and touches **no**
          row-level-secured table. The gate checks that claim rather than
          trusting it.
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

      Used by the scope gate and by the pairing tests, so "which jobs may see a
      user's rows" is answerable by running something rather than by reading
      37 files.
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
