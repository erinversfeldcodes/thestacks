defmodule Stacks.Workers.MockDbtRunner do
  @moduledoc false

  @behaviour Stacks.Workers.DbtRunnerBehaviour

  @impl true
  def run(_args) do
    case Process.get(:mock_dbt_result) do
      nil -> {:ok, "mock dbt run complete"}
      result -> result
    end
  end
end
