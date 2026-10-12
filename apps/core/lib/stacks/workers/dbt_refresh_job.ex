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

  # An empty selector is not a no-op to dbt: `--select ""` matches nothing and
  # still exits 0, so the warehouse would stale behind a job that looked green.
  def perform(%Oban.Job{args: %{"models" => []}}) do
    Logger.error("DbtRefreshJob: selective refresh requested with no models")
    {:error, "selective refresh requested with no models"}
  end

  def perform(%Oban.Job{args: %{"models" => models}}) when is_list(models) do
    runner = Application.get_env(:core, :dbt_runner, Stacks.Workers.DbtRunner)
    # dbt takes the whole selector list as ONE --select value. Passing each model
    # as its own argv entry makes every model after the first a positional
    # argument, which dbt rejects: `unknown argument "..." for "dbt run"`.
    args = ["run", "--select", Enum.join(models, " ")]

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
