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
  # ⚠️ The listing id comes from `aggregate_id`, NOT from the payload.
  #
  # This handler read `payload["listing_id"]`, and `Marketplace.activate/2`
  # emits `payload: %{book_id: …, seller_id: …}` with `aggregate_id: l.id`.
  # So the id was always `nil`, `get_listing(nil)` always returned `nil`, and
  # every activation logged "listing not found" and sent nothing. The
  # wishlist-availability email has never been delivered.
  #
  # Reading the aggregate id is the correct fix rather than adding
  # `listing_id` to the payload: the event's aggregate IS the listing, so the
  # id is already there and duplicating it into the payload would create two
  # places for it to disagree.
  def handle_event(%{event_type: "listing.activated", aggregate_id: listing_id}) do
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
    listing.book_id
    |> Shelving.users_with_book_on_wishlist()
    |> Enum.each(&maybe_notify_user(&1, listing))

    :ok
  end

  defp maybe_notify_user(user, listing) do
    if user.notify_wishlist_availability do
      enqueue_email(user.id, listing.id, listing.book_id)
    end
  end

  # ⚠️ Ids only. `seller_name` is a THIRD PARTY's name — the job's `user_id` is
  # the recipient, the seller is someone else — and `oban_jobs.args` is a
  # queryable table with no erasure path that now retains rows for seven days.
  # A scrub keyed on `args->>'user_id'` could never reach a name belonging to a
  # different person, so the only safe shape is not to put it there.
  #
  # The worker loads the listing at delivery and reads the title, author, price
  # and seller from it. That also means the email renders from current state,
  # which for an availability notice is more correct than a stale snapshot.
  defp enqueue_email(user_id, listing_id, book_id) do
    args = %{
      "template" => "wishlist_available",
      "user_id" => user_id,
      "book_id" => book_id,
      "params" => %{"listing_id" => listing_id}
    }

    # ⚠️ `keys:` reads TOP-LEVEL args only, so `book_id` and `user_id` must stay
    # where they are. `Oban.Engines.Basic.unique_map_values/3` does
    # `Map.take(args, keys)` — and `Map.take/2` SILENTLY DROPS absent keys. Move
    # `book_id` into `params` as a tidy and the uniqueness quietly collapses to
    # `user_id` alone: one wishlist email per user per 24 hours across every
    # book, with no error and no log.
    #
    # `:worker` is restored to `fields:` deliberately. The default is
    # `~w(args queue worker)a`; overriding it with `[:args]` dropped `worker`,
    # and the comparison is JSONB CONTAINMENT (`? @> ?`), not equality — so any
    # other job whose args merely CONTAIN this `user_id` and `book_id` would
    # collide with this one, in whichever direction inserted second. No worker
    # carries both keys today, but nothing stopped one from starting to.
    opts = [unique: [fields: [:worker, :args], keys: [:book_id, :user_id], period: 86_400]]

    case EmailDeliveryJob.new(args, opts) |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("WishlistAvailabilityHandler: failed to enqueue: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
