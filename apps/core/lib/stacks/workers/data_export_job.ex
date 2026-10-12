defmodule Stacks.Workers.DataExportJob do
  @moduledoc """
      Oban worker that generates, stores, and delivers a GDPR data export.

      Gathering the data is `Stacks.GDPR.Export`; getting it to the user is
      `Stacks.GDPR.ExportDelivery`. Neither leg may end quietly: the user has
      been told an email is coming, so a failure anywhere returns an error and
      spends a retry rather than reporting success on an export nobody
      received.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.GDPR.Export
  alias Stacks.GDPR.ExportDelivery

  @impl true
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    Logger.info("DataExportJob: generating export for user #{user_id}")
    started_at = System.monotonic_time()

    with {:ok, data} <- Export.export_user_data(user_id),
         {:ok, delivery} <- ExportDelivery.deliver(user_id, data) do
      Logger.info(
        "DataExportJob: export delivered for user #{user_id}, keys=#{map_size(data)}, " <>
          "bytes=#{delivery.bytes}, link expires #{DateTime.to_iso8601(delivery.expires_at)}"
      )

      emit_outcome(:ok, started_at)
      :ok
    else
      {:error, reason} ->
        Logger.error("DataExportJob: export failed for user #{user_id}: #{inspect(reason)}")
        emit_outcome(:error, started_at)
        {:error, reason}
    end
  end

  defp emit_outcome(result, started_at) do
    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    :telemetry.execute([:stacks, :gdpr, :export], %{count: 1, duration: duration_ms}, %{
      result: result
    })
  end
end
