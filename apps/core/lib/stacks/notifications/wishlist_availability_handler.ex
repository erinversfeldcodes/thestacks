defmodule Stacks.Notifications.WishlistAvailabilityHandler do
  @moduledoc """
      Event handler that enqueues wishlist availability emails when a listing is
      activated. Notifies all users who have the book on their wishlist and have
      `notify_wishlist_availability` enabled.

      Uses Oban unique job deduplication (24-hour window per book+user pair) to
      prevent notification spam when a listing is re-activated.

      Implements `Stacks.Events.Handler` and is registered in
      `Stacks.Events.Registry` for the `"listing.activated"` event type.
  """

  @behaviour Stacks.Events.Handler

  require Logger

  alias Stacks.Marketplace
  alias Stacks.Shelving
  alias Stacks.Workers.EmailDeliveryJob

  @impl true
  @spec handle_event(map()) :: :ok | {:error, term()}
  def handle_event(%{event_type: "listing.activated", payload: payload}) do
    listing_id = Map.get(payload, "listing_id") || Map.get(payload, :listing_id)

    case Marketplace.get_listing(listing_id) do
      nil ->
        Logger.warning("WishlistAvailabilityHandler: listing #{listing_id} not found, skipping")

        :ok

      listing ->
        notify_wishlist_users(listing)
    end
  end

  def handle_event(_event), do: :ok

  defp notify_wishlist_users(listing) do
    book_id = listing.book_id
    book_title = (listing.book && listing.book.title) || "A book"
    author_name = extract_author_name(listing.book)
    price_zar = format_price(listing.price_cents)
    seller_name = (listing.seller && listing.seller.display_name) || "a seller"

    book_id
    |> Shelving.users_with_book_on_wishlist()
    |> Enum.each(&maybe_notify_user(&1, book_id, book_title, author_name, price_zar, seller_name))

    :ok
  end

  defp maybe_notify_user(user, book_id, book_title, author_name, price_zar, seller_name) do
    if user.notify_wishlist_availability do
      enqueue_email(user.id, book_id, book_title, author_name, price_zar, seller_name)
    end
  end

  defp extract_author_name(nil), do: ""

  defp extract_author_name(book) do
    case book.author do
      %Ecto.Association.NotLoaded{} -> ""
      nil -> ""
      author -> author.name || ""
    end
  end

  defp format_price(nil), do: "0"
  defp format_price(cents), do: :erlang.float_to_binary(cents / 100, decimals: 2)

  defp enqueue_email(user_id, book_id, book_title, author_name, price_zar, seller_name) do
    args = %{
      "template" => "wishlist_available",
      "user_id" => user_id,
      "book_id" => book_id,
      "params" => %{
        "book_title" => book_title,
        "author_name" => author_name,
        "price_zar" => price_zar,
        "seller_name" => seller_name
      }
    }

    opts = [unique: [fields: [:args], keys: [:book_id, :user_id], period: 86_400]]

    case EmailDeliveryJob.new(args, opts) |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("WishlistAvailabilityHandler: failed to enqueue: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
