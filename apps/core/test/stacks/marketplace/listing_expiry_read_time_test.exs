defmodule Stacks.Marketplace.ListingExpiryReadTimeTest do
  @moduledoc """
  A listing past `expires_at` must read as expired whether or not anything has written
  that down.

  `ListingExpiryJob` used to be the only thing that made it so, which made a cron entry
  load-bearing for correctness: with the platform scaling to zero the job may not fire,
  and an expired listing then showed as available and could still be bought.
  """

  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Marketplace

  defp listing_with_expiry(expires_at, attrs \\ []) do
    # Inserted with status "active" on purpose: this is exactly the state the cron
    # would have corrected and has not.
    insert(
      :listing,
      Keyword.merge(
        [status: "active", expires_at: expires_at, listed_at: DateTime.utc_now()],
        attrs
      )
    )
  end

  describe "browsing" do
    test "an expired listing is not offered as available" do
      past = listing_with_expiry(DateTime.add(DateTime.utc_now(), -1, :day))
      live = listing_with_expiry(DateTime.add(DateTime.utc_now(), 10, :day))

      ids = Marketplace.list_active_listings() |> Enum.map(& &1.id)

      assert live.id in ids
      refute past.id in ids, "an expired listing must not appear as available"
    end

    test "a listing with no expiry is still available" do
      # Nullable column: absent expiry means it does not expire, not that it expired.
      forever = listing_with_expiry(nil)

      assert forever.id in (Marketplace.list_active_listings() |> Enum.map(& &1.id))
    end

    test "expiry is exclusive at the boundary" do
      # `expires_at` in the past by a second is expired; the future is not.
      just_past = listing_with_expiry(DateTime.add(DateTime.utc_now(), -1, :second))
      just_future = listing_with_expiry(DateTime.add(DateTime.utc_now(), 60, :second))

      ids = Marketplace.list_active_listings() |> Enum.map(& &1.id)

      refute just_past.id in ids
      assert just_future.id in ids
    end
  end

  describe "reading one listing" do
    test "reports expired status even though the row still says active" do
      # Callers act on `listing.status` — accepting an offer, say — so the read is what
      # has to tell the truth.
      past = listing_with_expiry(DateTime.add(DateTime.utc_now(), -1, :day))

      assert Core.Repo.get!(Stacks.Marketplace.Listing, past.id).status == "active",
             "precondition: the stored row is still active, as the cron never ran"

      assert Marketplace.get_listing(past.id).status == "expired"
    end

    test "leaves a live listing alone" do
      live = listing_with_expiry(DateTime.add(DateTime.utc_now(), 10, :day))
      assert Marketplace.get_listing(live.id).status == "active"
    end

    test "does not resurrect a sold listing as expired" do
      # Only "active" is derived. A sold listing stays sold whatever its expiry says.
      sold =
        listing_with_expiry(DateTime.add(DateTime.utc_now(), -1, :day), status: "sold")

      assert Marketplace.get_listing(sold.id).status == "sold"
    end
  end

  describe "discovery labels" do
    test "an expired listing does not label a book as listed" do
      past = listing_with_expiry(DateTime.add(DateTime.utc_now(), -1, :day))

      assert Marketplace.active_listing_labels([past.book_id]) == %{}
    end

    test "a live listing does label its book" do
      live = listing_with_expiry(DateTime.add(DateTime.utc_now(), 10, :day))

      labels = Marketplace.active_listing_labels([live.book_id])
      assert labels[live.book_id][:source] == "listed"
    end
  end

  describe "a seller's own listings" do
    test "keep expired entries, but each says it is expired" do
      # Sellers need to see them to relist.
      past = listing_with_expiry(DateTime.add(DateTime.utc_now(), -1, :day))

      mine = Marketplace.list_user_listings(past.seller_id)
      found = Enum.find(mine, &(&1.id == past.id))

      assert found, "a seller must still see their expired listing"
      assert found.status == "expired"
    end
  end
end
