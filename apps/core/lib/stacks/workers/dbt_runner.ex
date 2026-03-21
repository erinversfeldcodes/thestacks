defmodule Stacks.Workers.DbtRunner do
  @moduledoc false

  @behaviour Stacks.Workers.DbtRunnerBehaviour

  @impl true
  def run(args) do
    case System.cmd("dbt", args, cd: dbt_dir(), stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end
  end

  defp dbt_dir do
    Application.get_env(:core, :dbt_dir, Path.join(File.cwd!(), "../../dbt"))
  end
end
