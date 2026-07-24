defmodule Stacks.MarketplaceTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Marketplace
  alias Stacks.Marketplace.Listing
  alias Stacks.Shelving.Placement

  defp setup_seller_with_placement(_ctx) do
    seller = insert(:user)
    book = insert(:book)
    bookshelf = insert(:bookshelf, user: seller, name: "looking_for_home")
    placement = insert(:placement, bookshelf: bookshelf, book: book)

    %{seller: seller, book: book, bookshelf: bookshelf, placement: placement}
  end

  defp valid_listing_attrs(book_id) do
    %{
      book_id: book_id,
      pricing_mode: "fixed",
      price_cents: 15_000,
      condition: "good",
      description: "Good condition copy."
    }
  end

  # ---------------------------------------------------------------------------
  # create_listing/2
  # ---------------------------------------------------------------------------

  describe "create_listing/2" do
    setup :setup_seller_with_placement

    test "creates a draft listing when seller owns a placement", %{seller: seller, book: book} do
      assert {:ok, %Listing{} = listing} =
               Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))

      assert listing.status == "draft"
      assert listing.seller_id == seller.id
      assert listing.book_id == book.id
      assert listing.price_cents == 15_000
    end

    test "emits listing.created event", %{seller: seller, book: book} do
      assert {:ok, _listing} =
               Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))

      assert Repo.exists?(
               from(e in "event_log",
                 prefix: "op",
                 where: e.event_type == "listing.created"
               )
             )
    end

    test "returns :no_placement when seller has no placement for the book", %{seller: seller} do
      other_book = insert(:book)

      assert {:error, :no_placement} =
               Marketplace.create_listing(seller.id, valid_listing_attrs(other_book.id))
    end

    test "returns :no_placement when book_id is nil", %{seller: seller} do
      assert {:error, :no_placement} =
               Marketplace.create_listing(seller.id, valid_listing_attrs(nil))
    end

    test "returns changeset error for invalid attrs", %{seller: seller, book: book} do
      assert {:error, %Ecto.Changeset{}} =
               Marketplace.create_listing(seller.id, %{book_id: book.id})
    end

    test "rejects zero price_cents", %{seller: seller, book: book} do
      attrs = valid_listing_attrs(book.id) |> Map.put(:price_cents, 0)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Marketplace.create_listing(seller.id, attrs)

      assert errors_on(changeset).price_cents != []
    end

    test "rejects negative price_cents", %{seller: seller, book: book} do
      attrs = valid_listing_attrs(book.id) |> Map.put(:price_cents, -100)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Marketplace.create_listing(seller.id, attrs)

      assert errors_on(changeset).price_cents != []
    end
  end

  # ---------------------------------------------------------------------------
  # get_listing/1
  # ---------------------------------------------------------------------------

  describe "get_listing/1" do
    test "returns listing with book and seller preloaded" do
      listing = insert(:listing)

      fetched = Marketplace.get_listing(listing.id)

      assert fetched.id == listing.id
      assert fetched.book != nil
      assert fetched.seller != nil
    end

    test "returns nil for nonexistent id" do
      assert Marketplace.get_listing(Ecto.UUID.generate()) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # list_active_listings/0
  # ---------------------------------------------------------------------------

  describe "list_active_listings/0" do
    test "returns only active listings" do
      insert(:listing, status: "active", listed_at: DateTime.utc_now())
      insert(:listing, status: "draft")
      insert(:listing, status: "removed")

      listings = Marketplace.list_active_listings()

      assert length(listings) == 1
      assert hd(listings).status == "active"
    end

    test "returns empty list when no active listings exist" do
      insert(:listing, status: "draft")
      assert Marketplace.list_active_listings() == []
    end
  end

  # ---------------------------------------------------------------------------
  # list_user_listings/1
  # ---------------------------------------------------------------------------

  describe "list_user_listings/1" do
    test "returns all listings for a seller" do
      seller = insert(:user)
      insert(:listing, seller: seller, status: "draft")
      insert(:listing, seller: seller, status: "active", listed_at: DateTime.utc_now())
      insert(:listing)

      listings = Marketplace.list_user_listings(seller.id)

      assert length(listings) == 2
      assert Enum.all?(listings, &(&1.seller_id == seller.id))
    end
  end

  # ---------------------------------------------------------------------------
  # activate_listing/2
  # ---------------------------------------------------------------------------

  describe "activate_listing/2" do
    setup :setup_seller_with_placement

    test "transitions draft → active and sets listed_at and expires_at", %{
      seller: seller,
      book: book
    } do
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))

      assert {:ok, %Listing{} = activated} = Marketplace.activate_listing(listing, seller.id)

      assert activated.status == "active"
      assert activated.listed_at != nil
      assert activated.expires_at != nil
    end

    test "denormalizes listing_status on placement", %{
      seller: seller,
      book: book,
      placement: placement
    } do
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))
      {:ok, _activated} = Marketplace.activate_listing(listing, seller.id)

      updated_placement = Repo.get!(Placement, placement.id)
      assert updated_placement.listing_status == "active"
    end

    test "emits listing.activated event", %{seller: seller, book: book} do
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))
      {:ok, _activated} = Marketplace.activate_listing(listing, seller.id)

      assert Repo.exists?(
               from(e in "event_log",
                 prefix: "op",
                 where: e.event_type == "listing.activated"
               )
             )
    end

    test "returns :unauthorized when user is not the seller", %{book: book, seller: seller} do
      other_user = insert(:user)
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))

      assert {:error, :unauthorized} = Marketplace.activate_listing(listing, other_user.id)
    end

    test "returns :invalid_transition for active → active", %{seller: seller, book: book} do
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))
      {:ok, activated} = Marketplace.activate_listing(listing, seller.id)

      assert {:error, :invalid_transition} = Marketplace.activate_listing(activated, seller.id)
    end

    test "returns :invalid_transition for removed → active", %{seller: seller, book: book} do
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))
      {:ok, activated} = Marketplace.activate_listing(listing, seller.id)
      {:ok, removed} = Marketplace.deactivate_listing(activated, seller.id)

      assert {:error, :invalid_transition} = Marketplace.activate_listing(removed, seller.id)
    end
  end

  # ---------------------------------------------------------------------------
  # deactivate_listing/2
  # ---------------------------------------------------------------------------

  describe "deactivate_listing/2" do
    setup :setup_seller_with_placement

    test "transitions active → removed", %{seller: seller, book: book} do
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))
      {:ok, activated} = Marketplace.activate_listing(listing, seller.id)

      assert {:ok, %Listing{status: "removed"}} =
               Marketplace.deactivate_listing(activated, seller.id)
    end

    test "clears listing_status on placement", %{seller: seller, book: book, placement: placement} do
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))
      {:ok, activated} = Marketplace.activate_listing(listing, seller.id)
      {:ok, _removed} = Marketplace.deactivate_listing(activated, seller.id)

      updated_placement = Repo.get!(Placement, placement.id)
      assert updated_placement.listing_status == nil
    end

    test "emits listing.removed event", %{seller: seller, book: book} do
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))
      {:ok, activated} = Marketplace.activate_listing(listing, seller.id)
      {:ok, _removed} = Marketplace.deactivate_listing(activated, seller.id)

      assert Repo.exists?(
               from(e in "event_log",
                 prefix: "op",
                 where: e.event_type == "listing.removed"
               )
             )
    end

    test "returns :invalid_transition for draft → removed", %{seller: seller, book: book} do
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))

      assert {:error, :invalid_transition} = Marketplace.deactivate_listing(listing, seller.id)
    end

    test "returns :unauthorized for non-owner", %{seller: seller, book: book} do
      other_user = insert(:user)
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))
      {:ok, activated} = Marketplace.activate_listing(listing, seller.id)

      assert {:error, :unauthorized} = Marketplace.deactivate_listing(activated, other_user.id)
    end
  end

  # ---------------------------------------------------------------------------
  # sold_listing/2
  # ---------------------------------------------------------------------------

  describe "sold_listing/2" do
    setup :setup_seller_with_placement

    test "transitions active → sold and sets sold_at", %{seller: seller, book: book} do
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))
      {:ok, activated} = Marketplace.activate_listing(listing, seller.id)

      assert {:ok, %Listing{status: "sold"} = sold} =
               Marketplace.sold_listing(activated, seller.id)

      assert sold.sold_at != nil
    end

    test "clears listing_status on placement", %{
      seller: seller,
      book: book,
      placement: placement
    } do
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))
      {:ok, activated} = Marketplace.activate_listing(listing, seller.id)
      {:ok, _sold} = Marketplace.sold_listing(activated, seller.id)

      updated_placement = Repo.get!(Placement, placement.id)
      assert updated_placement.listing_status == nil
    end

    test "emits listing.sold event", %{seller: seller, book: book} do
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))
      {:ok, activated} = Marketplace.activate_listing(listing, seller.id)
      {:ok, _sold} = Marketplace.sold_listing(activated, seller.id)

      assert Repo.exists?(
               from(e in "event_log",
                 prefix: "op",
                 where: e.event_type == "listing.sold"
               )
             )
    end

    test "returns :invalid_transition for draft → sold", %{seller: seller, book: book} do
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))

      assert {:error, :invalid_transition} = Marketplace.sold_listing(listing, seller.id)
    end

    test "returns :unauthorized for non-owner", %{seller: seller, book: book} do
      other_user = insert(:user)
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))
      {:ok, activated} = Marketplace.activate_listing(listing, seller.id)

      assert {:error, :unauthorized} = Marketplace.sold_listing(activated, other_user.id)
    end
  end

  # ---------------------------------------------------------------------------
  # expire_listing/1
  # ---------------------------------------------------------------------------

  describe "expire_listing/1" do
    setup :setup_seller_with_placement

    test "transitions active → expired", %{seller: seller, book: book} do
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))
      {:ok, activated} = Marketplace.activate_listing(listing, seller.id)

      assert {:ok, %Listing{status: "expired"}} = Marketplace.expire_listing(activated)
    end

    test "clears listing_status on placement", %{seller: seller, book: book, placement: placement} do
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))
      {:ok, activated} = Marketplace.activate_listing(listing, seller.id)
      {:ok, _expired} = Marketplace.expire_listing(activated)

      updated_placement = Repo.get!(Placement, placement.id)
      assert updated_placement.listing_status == nil
    end

    test "emits listing.expired event", %{seller: seller, book: book} do
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))
      {:ok, activated} = Marketplace.activate_listing(listing, seller.id)
      {:ok, _expired} = Marketplace.expire_listing(activated)

      assert Repo.exists?(
               from(e in "event_log",
                 prefix: "op",
                 where: e.event_type == "listing.expired"
               )
             )
    end

    test "returns :invalid_transition for draft → expired", %{seller: seller, book: book} do
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))

      assert {:error, :invalid_transition} = Marketplace.expire_listing(listing)
    end
  end

  # ---------------------------------------------------------------------------
  # State machine — disallowed transitions
  # ---------------------------------------------------------------------------

  describe "state machine — disallowed transitions" do
    setup :setup_seller_with_placement

    test "expired → active is invalid", %{seller: seller, book: book} do
      {:ok, listing} = Marketplace.create_listing(seller.id, valid_listing_attrs(book.id))
      {:ok, activated} = Marketplace.activate_listing(listing, seller.id)
      {:ok, expired} = Marketplace.expire_listing(activated)

      assert {:error, :invalid_transition} = Marketplace.activate_listing(expired, seller.id)
    end

    test "sold → active is invalid" do
      listing = insert(:listing, status: "sold")
      user = listing.seller

      assert {:error, :invalid_transition} = Marketplace.activate_listing(listing, user.id)
    end
  end

  # #285 — discovery-label helpers used by the sectioned search response.
  describe "format_price/2" do
    test "renders whole-rand ZAR amounts without decimals" do
      assert Marketplace.format_price(12_000, "ZAR") == "R120"
    end

    test "renders fractional ZAR amounts with two decimals" do
      assert Marketplace.format_price(12_050, "ZAR") == "R120.50"
      assert Marketplace.format_price(12_005, "ZAR") == "R120.05"
    end

    test "falls back to a currency-code prefix for non-ZAR currencies" do
      assert Marketplace.format_price(9_900, "USD") == "USD 99"
    end
  end

  describe "active_listing_labels/1" do
    test "returns a 'listed' label with seller handle and formatted price" do
      seller = insert(:user, handle: "seller_one")
      book = insert(:book)
      insert(:listing, book: book, seller: seller, status: "active", price_cents: 7_500)

      labels = Marketplace.active_listing_labels([book.id])
      book_id = book.id

      assert %{^book_id => %{source: "listed", owner_handle: "seller_one", price: "R75"}} = labels
    end

    test "omits draft/removed/sold listings and unknown book ids" do
      book = insert(:book)
      insert(:listing, book: book, status: "draft", price_cents: 5_000)

      assert Marketplace.active_listing_labels([book.id]) == %{}
      assert Marketplace.active_listing_labels([]) == %{}
    end
  end
end
