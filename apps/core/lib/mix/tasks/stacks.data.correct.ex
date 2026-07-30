defmodule Mix.Tasks.Stacks.Data.Correct do
  @shortdoc "Dry-run (or apply) the registered data corrections"

  @moduledoc """
  Runs the corrections in `Stacks.DataCorrection.Registry` against the
  configured database.

  **Dry-run by default.** Without `--apply` this prints exactly which rows each
  correction would change and to what, and writes nothing. That report is the
  blast radius; read it before applying.

  ## Usage (from `apps/core/`)

      mix stacks.data.correct                 # dry-run everything
      mix stacks.data.correct --apply         # apply everything
      mix stacks.data.correct --only normalise_edition_isbn10

  On a deployed stack there is no `mix`; use the release entry point instead:

      /app/bin/core eval 'Stacks.Release.correct_data()'          # dry-run
      /app/bin/core eval 'Stacks.Release.correct_data(apply: true)'

  ## Options

    * `--apply` — write the changes. Each applied change is recorded in
      `audit.audit_log` in the same transaction as the change itself.
    * `--only NAME` — restrict to one correction by its `name/0`. Repeatable.

  ## Exit code

  Non-zero when a correction failed, so a script can gate on it. A dry-run that
  finds rows still exits zero — finding work to do is not an error.
  """

  use Mix.Task

  alias Core.Repo
  alias Stacks.DataCorrection
  alias Stacks.DataCorrection.Registry

  @switches [apply: :boolean, only: :keep]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    # `--no-start`, then a repo of our own: the same shape `mix ecto.migrate`
    # uses, and for the same reason. `scripts/deploy-stack.sh` runs this on the
    # CI runner under MIX_ENV=prod immediately before migrating, where starting
    # the full application tree would boot the endpoint, Oban and every circuit
    # breaker just to update a handful of rows.
    Mix.Task.run("app.start", ["--no-start"])

    corrections = select(Keyword.get_values(opts, :only))

    {:ok, _apps, _started} =
      Ecto.Migrator.with_repo(Repo, fn _repo ->
        report(corrections, Keyword.get(opts, :apply, false))
      end)
  end

  defp report(corrections, apply?) do
    case DataCorrection.run_all(corrections,
           apply: apply?,
           invoked_by: "mix stacks.data.correct"
         ) do
      {:ok, outcomes} ->
        Enum.each(outcomes, &Mix.shell().info(&1.report))
        Mix.shell().info("")
        Mix.shell().info("total rows: #{Enum.sum(Enum.map(outcomes, & &1.count))}")

      {:error, {correction, reason}} ->
        Mix.raise("#{inspect(correction)} failed: #{inspect(reason)} — nothing was committed")
    end
  end

  defp select([]), do: Registry.all()

  defp select(names) do
    case Enum.filter(Registry.all(), &(&1.name() in names)) do
      [] -> Mix.raise("no correction named #{Enum.join(names, ", ")}")
      selected -> selected
    end
  end
end
