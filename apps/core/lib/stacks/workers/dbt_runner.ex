defmodule Stacks.Workers.DbtRunner do
  @moduledoc false

  @behaviour Stacks.Workers.DbtRunnerBehaviour

  @default_dbt_dir Path.expand("../../../../../dbt", __DIR__)

  @impl true
  def run(args) do
    case System.cmd("dbt", args, cd: dbt_dir(), stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end
  end

  @doc false
  def dbt_dir do
    Application.get_env(:core, :dbt_dir, @default_dbt_dir)
  end
end
