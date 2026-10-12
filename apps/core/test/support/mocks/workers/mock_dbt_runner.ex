defmodule Stacks.Workers.MockDbtRunner do
  @moduledoc false

  @behaviour Stacks.Workers.DbtRunnerBehaviour

  @impl true
  def run(args) do
    Process.put(:mock_dbt_args, args)

    case Process.get(:mock_dbt_result) do
      nil -> {:ok, "mock dbt run complete"}
      result -> result
    end
  end

  @doc """
  The argv the caller last handed to the runner, or `nil` if it was never called.

  Recorded so tests can assert the exact argv dbt would receive — a mock that
  discards its arguments cannot tell a valid invocation from a malformed one.
  """
  def last_args, do: Process.get(:mock_dbt_args)
end
