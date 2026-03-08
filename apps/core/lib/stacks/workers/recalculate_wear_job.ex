defmodule Stacks.Workers.RecalculateWearJob do
  @moduledoc """
  Oban worker that recalculates the wear level for a book placement
  based on its movement history count.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.Shelving

  @impl true
  def perform(%Oban.Job{args: %{"placement_id" => placement_id}}) do
    Logger.info("RecalculateWearJob: recalculating wear for placement #{placement_id}")

    case Shelving.spine_data(placement_id) do
      nil ->
        Logger.warning("RecalculateWearJob: placement #{placement_id} not found")
        {:cancel, "placement not found"}

      spine ->
        Logger.info(
          "RecalculateWearJob: placement #{placement_id} wear_level=#{spine.wear_level}"
        )

        :ok
    end
  end
end
