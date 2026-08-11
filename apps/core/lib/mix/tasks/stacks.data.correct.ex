defmodule Mix.Tasks.Stacks.Data.Correct do
  @shortdoc "Dry-run (or apply) the registered data corrections"

  @moduledoc """
  Runs the corrections in `DataCorrection.Registry`. DRY-RUN BY DEFAULT —
  without `--apply` it prints the blast radius and writes nothing. `--only
  NAME` restricts (repeatable). Applied changes are audited in the same
  transaction. On a deployed stack use
  `/app/bin/core eval 'Stacks.Release.correct_data(apply: true)'`.
  Exit is non-zero when any correction errors, so CI/deploy can gate on it.
  """

  use Mix.Task

  alias Core.Repo
  alias Stacks.DataCorrection
  alias Stacks.DataCorrection.Registry

  @switches [apply: :boolean, only: :keep]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

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
