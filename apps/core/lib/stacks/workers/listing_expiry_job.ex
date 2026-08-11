defmodule Stacks.Workers.ListingExpiryJob do
  @moduledoc """
    Daily Oban cron worker that expires active listings past their `expires_at`.

    Scheduled at 1 AM UTC. Finds active listings where `expires_at` is in
    the past and transitions each to `expired` status, clearing the
    denormalized `listing_status` on the seller's placement.

    Processes in batches of 500 to avoid unbounded memory usage.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Marketplace
  alias Stacks.Marketplace.Listing

  @batch_size 500

  @impl true
  def perform(_job) do
    now = DateTime.utc_now()

    expired_listings =
      Listing
      |> where([l], l.status == "active" and l.expires_at <= ^now)
      |> order_by([l], asc: l.expires_at)
      |> limit(@batch_size)
      |> Repo.all()

    expired_count =
      Enum.reduce(expired_listings, 0, fn listing, count ->
        case Marketplace.expire_listing(listing) do
          {:ok, _} ->
            count + 1

          {:error, reason} ->
            Logger.warning(
              "ListingExpiryJob: failed to expire listing #{listing.id}: #{inspect(reason)}"
            )

            count
        end
      end)

    Logger.info("ListingExpiryJob: expired #{expired_count} listing(s)")

    if length(expired_listings) == @batch_size do
      %{} |> __MODULE__.new() |> Oban.insert()
    end

    :ok
  end
end
