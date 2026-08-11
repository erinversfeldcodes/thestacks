defmodule Stacks.Notifications.OfferNotificationHandler do
  @moduledoc """
    Event handler that enqueues a new-offer email to the seller when an offer
    is opened on their listing.

    Implements `Stacks.Events.Handler` and is registered in
    `Stacks.Events.Registry` for the `"offer.opened"` event type.
  """

  @behaviour Stacks.Events.Handler

  require Logger

  alias Stacks.Marketplace
  alias Stacks.Workers.EmailDeliveryJob

  @impl true
  @spec handle_event(map()) :: :ok | {:error, term()}
  def handle_event(%{event_type: "offer.opened", payload: payload}) do
    listing_id = Map.get(payload, "listing_id") || Map.get(payload, :listing_id)
    buyer_name = Map.get(payload, "buyer_name") || Map.get(payload, :buyer_name, "A buyer")
    offer_amount_zar = Map.get(payload, "offer_amount_zar") || Map.get(payload, :offer_amount_zar)
    offer_id = Map.get(payload, "offer_id") || Map.get(payload, :offer_id)
    offer_url = "/marketplace/offers/#{offer_id}"

    do_notify(
      Marketplace.get_listing(listing_id),
      listing_id,
      buyer_name,
      offer_amount_zar,
      offer_url
    )
  end

  def handle_event(_event), do: :ok

  defp do_notify(nil, listing_id, _buyer_name, _amount, _offer_url) do
    Logger.warning("OfferNotificationHandler: listing #{listing_id} not found, skipping")
    :ok
  end

  defp do_notify(listing, listing_id, buyer_name, offer_amount_zar, offer_url) do
    do_notify_seller(listing.seller, listing, listing_id, buyer_name, offer_amount_zar, offer_url)
  end

  defp do_notify_seller(nil, _listing, listing_id, _buyer_name, _amount, _offer_url) do
    Logger.warning(
      "OfferNotificationHandler: seller not found for listing #{listing_id}, skipping"
    )

    :ok
  end

  defp do_notify_seller(seller, listing, _listing_id, buyer_name, offer_amount_zar, offer_url) do
    if seller.notify_marketplace do
      listing_title = (listing.book && listing.book.title) || "your listing"
      enqueue_email(seller.id, buyer_name, listing_title, offer_amount_zar, offer_url)
    else
      :ok
    end
  end

  defp enqueue_email(user_id, buyer_name, listing_title, offer_amount_zar, offer_url) do
    args = %{
      "template" => "new_offer",
      "user_id" => user_id,
      "params" => %{
        "buyer_name" => buyer_name,
        "listing_title" => listing_title,
        "offer_amount_zar" => offer_amount_zar,
        "offer_url" => offer_url
      }
    }

    case EmailDeliveryJob.new(args) |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("OfferNotificationHandler: failed to enqueue: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
