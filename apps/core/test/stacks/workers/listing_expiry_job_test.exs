defmodule Stacks.Workers.ListingExpiryJobTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Marketplace.Listing
  alias Stacks.Shelving.Placement
  alias Stacks.Workers.ListingExpiryJob

  describe "perform/1" do
    test "expires active listings past their expires_at" do
      past = DateTime.add(DateTime.utc_now(), -1, :day)

      listing =
        insert(:listing,
          status: "active",
          listed_at: DateTime.add(DateTime.utc_now(), -31, :day),
          expires_at: past
        )

      assert :ok = perform_job(ListingExpiryJob, %{})

      updated = Repo.get!(Listing, listing.id)
      assert updated.status == "expired"
    end

    test "does not expire active listings before their expires_at" do
      future = DateTime.add(DateTime.utc_now(), 10, :day)

      listing =
        insert(:listing,
          status: "active",
          listed_at: DateTime.utc_now(),
          expires_at: future
        )

      assert :ok = perform_job(ListingExpiryJob, %{})

      updated = Repo.get!(Listing, listing.id)
      assert updated.status == "active"
    end

    test "does not touch draft listings" do
      past = DateTime.add(DateTime.utc_now(), -1, :day)

      listing =
        insert(:listing,
          status: "draft",
          expires_at: past
        )

      assert :ok = perform_job(ListingExpiryJob, %{})

      updated = Repo.get!(Listing, listing.id)
      assert updated.status == "draft"
    end

    test "clears listing_status on placement when expiring", %{} do
      past = DateTime.add(DateTime.utc_now(), -1, :day)
      seller = insert(:user)
      book = insert(:book)
      bookshelf = insert(:bookshelf, user: seller, name: "looking_for_home")

      placement =
        insert(:placement,
          bookshelf: bookshelf,
          book: book,
          listing_status: "active"
        )

      insert(:listing,
        seller: seller,
        book: book,
        status: "active",
        listed_at: DateTime.add(DateTime.utc_now(), -31, :day),
        expires_at: past
      )

      assert :ok = perform_job(ListingExpiryJob, %{})

      updated_placement = Repo.get!(Placement, placement.id)
      assert updated_placement.listing_status == nil
    end

    test "handles no expired listings gracefully" do
      assert :ok = perform_job(ListingExpiryJob, %{})
    end
  end
end
