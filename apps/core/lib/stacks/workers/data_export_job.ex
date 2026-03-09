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

    case Export.export_user_data(user_id) do
      {:ok, data} ->
        # Stub: in production, write to object storage and notify user
        Logger.info("DataExportJob: export generated for user #{user_id}, keys=#{map_size(data)}")
        :ok

      {:error, reason} ->
        Logger.error("DataExportJob: export failed for user #{user_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
