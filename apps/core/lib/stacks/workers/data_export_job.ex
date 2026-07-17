defmodule Stacks.Workers.DataExportJob do
  @moduledoc """
  Oban worker that generates and stores a GDPR data export for a user.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.GDPR.Export

  @impl true
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    Logger.info("DataExportJob: generating export for user #{user_id}")
    started_at = System.monotonic_time()

    case Export.export_user_data(user_id) do
      {:ok, data} ->
        # Stub: in production, write to object storage and notify user
        Logger.info("DataExportJob: export generated for user #{user_id}, keys=#{map_size(data)}")
        emit_outcome(:ok, started_at)
        :ok

      {:error, reason} ->
        Logger.error("DataExportJob: export failed for user #{user_id}: #{inspect(reason)}")
        emit_outcome(:error, started_at)
        {:error, reason}
    end
  end

  # GDPR telemetry (technical-architecture "Observability & Metrics"):
  # one event per export job carrying the terminal outcome AND the job
  # wall-time. Registered in `Core.PromEx.Plugins.Stacks` as
  # `stacks_gdpr_export_count_total` (counter, tagged `:result`) and
  # `stacks_gdpr_export_duration_milliseconds` (distribution, Issue #238) so
  # p95 can watch the 30-day portability SLA. `:duration` is milliseconds.
  defp emit_outcome(result, started_at) do
    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    :telemetry.execute([:stacks, :gdpr, :export], %{count: 1, duration: duration_ms}, %{
      result: result
    })
  end
end
