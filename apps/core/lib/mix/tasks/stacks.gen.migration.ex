defmodule Mix.Tasks.Stacks.Gen.Migration do
  @shortdoc "Generate a migration pre-filled with the lock/statement-timeout convention"

  @moduledoc """
      Like `mix ecto.gen.migration`, but the file it writes already carries the
      lock/statement-timeout convention and the reasoning behind it — so the
      author starts from the same rung the proto-sync generator does, instead of
      a bare `def change` that `security-squawk.sh` only objects to at the end of
      a full `just ci`.

      Usage:

          mix stacks.gen.migration add_foo_to_bar
          mix stacks.gen.migration add_index_on_big_table --concurrent

      Default (transactional) scaffold:

        * `SET LOCAL lock_timeout`/`statement_timeout` in both `up` and `down` —
          `SET LOCAL` because the settings revert when the migration's
          transaction commits. `lock_timeout` makes a contended lock fail fast
          instead of queueing every later query behind the migration.

      `--concurrent` scaffold, for `CREATE INDEX CONCURRENTLY`, `VALIDATE
      CONSTRAINT`, or any DDL that must not hold ACCESS EXCLUSIVE on a populated
      table — the non-obvious variant whose rules had to be hunted down:

        * `@disable_ddl_transaction true` — CONCURRENTLY cannot run inside a
          transaction;
        * plain `SET`, not `SET LOCAL` — there is no transaction for a LOCAL
          setting to scope to;
        * `statement_timeout = 0` — a timeout firing mid-build leaves an INVALID
          index behind, which is worse than a slow build; `lock_timeout` still
          protects availability.

      The scaffold's DDL lines are `TODO` placeholders. Fill them in; keep the
      timeout lines.
  """

  use Mix.Task

  @switches [concurrent: :boolean]
  @aliases [c: :concurrent]

  @impl Mix.Task
  def run(argv) do
    {opts, rest, _invalid} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    name =
      case rest do
        [n] ->
          n

        [] ->
          Mix.raise("expected a migration name, e.g. `mix stacks.gen.migration add_foo_to_bar`")

        _ ->
          Mix.raise("expected a single migration name, got: #{Enum.join(rest, " ")}")
      end

    unless name =~ ~r/^[a-z][a-z0-9_]*$/ do
      Mix.raise(
        "migration name must be snake_case (lowercase, digits, underscores), got: #{inspect(name)}"
      )
    end

    dir = migrations_dir()
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    path = Path.join(dir, "#{timestamp}_#{name}.exs")

    if File.exists?(path) do
      Mix.raise("migration already exists: #{path}")
    end

    module = "Core.Repo.Migrations.#{Macro.camelize(name)}"
    content = template(module, Keyword.get(opts, :concurrent, false))

    File.write!(path, content)
    Mix.shell().info("* creating #{path}")

    Mix.shell().info(
      "  it carries the timeout convention already; fill in the TODO DDL and keep the timeout lines."
    )
  end

  defp migrations_dir do
    cond do
      File.dir?("priv/repo/migrations") ->
        "priv/repo/migrations"

      File.dir?("apps/core/priv/repo/migrations") ->
        "apps/core/priv/repo/migrations"

      true ->
        Mix.raise("could not find priv/repo/migrations (run from the repo root or apps/core)")
    end
  end

  defp template(module, true) do
    """
    defmodule #{module} do
      use Ecto.Migration

      # The CONCURRENT variant: for `CREATE INDEX CONCURRENTLY`, `VALIDATE
      # CONSTRAINT`, or any DDL that must NOT hold ACCESS EXCLUSIVE on a populated
      # table. Its rules are the non-obvious ones:
      @disable_ddl_transaction true

      def up do
        # Plain `SET`, NOT `SET LOCAL`: there is no transaction here for a LOCAL
        # setting to scope to.
        execute("SET lock_timeout = '5s'")
        # `statement_timeout = 0` (unbounded): a timeout firing mid-build leaves
        # an INVALID index behind, which is worse than a slow build. The
        # lock_timeout above still makes a contended lock fail fast.
        execute("SET statement_timeout = 0")

        # TODO: your CONCURRENTLY / VALIDATE DDL here.
      end

      def down do
        execute("SET lock_timeout = '5s'")
        execute("SET statement_timeout = 0")

        # TODO: reverse it (or `:ok` if there is nothing to undo).
      end
    end
    """
  end

  defp template(module, false) do
    """
    defmodule #{module} do
      use Ecto.Migration

      # The lock/statement-timeout convention, handed to you here rather than
      # caught at the end of `just ci` by security-squawk. `SET LOCAL` scopes the
      # settings to this migration's transaction (they revert on commit).
      # `lock_timeout` makes a contended lock fail fast instead of queueing every
      # later query behind this migration; `statement_timeout` bounds a runaway
      # DDL. Adding an index to a POPULATED table? Use `--concurrent` instead —
      # `CREATE INDEX CONCURRENTLY` cannot run inside a transaction.

      def up do
        execute("SET LOCAL lock_timeout = '5s'")
        execute("SET LOCAL statement_timeout = '30s'")

        # TODO: your DDL here.
      end

      def down do
        execute("SET LOCAL lock_timeout = '5s'")
        execute("SET LOCAL statement_timeout = '30s'")

        # TODO: reverse it.
      end
    end
    """
  end
end
