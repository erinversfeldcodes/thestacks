defmodule Stacks.Workers.DbtRefreshJob do
  @moduledoc false

  use Oban.Worker,
    queue: :dbt_refresh,
    max_attempts: 3,
    unique: [period: 300, keys: [:models]]

  require Logger

  @impl true
  def perform(%Oban.Job{args: %{"full" => true}}) do
    runner = Application.get_env(:core, :dbt_runner, Stacks.Workers.DbtRunner)

    case runner.run(["run"]) do
      {:ok, output} ->
        Logger.info("DbtRefreshJob: full refresh complete")
        Logger.debug("DbtRefreshJob output: #{output}")
        :ok

      {:error, output} ->
        Logger.error("DbtRefreshJob: full refresh failed: #{output}")
        {:error, output}
    end
  end

  def perform(%Oban.Job{args: %{"models" => models}}) when is_list(models) do
    runner = Application.get_env(:core, :dbt_runner, Stacks.Workers.DbtRunner)
    args = ["run", "--select" | models]

    case runner.run(args) do
      {:ok, output} ->
        Logger.info("DbtRefreshJob: selective refresh complete for #{inspect(models)}")
        Logger.debug("DbtRefreshJob output: #{output}")
        :ok

      {:error, output} ->
        Logger.error("DbtRefreshJob: selective refresh failed for #{inspect(models)}: #{output}")
        {:error, output}
    end
  end
end
