defmodule Stacks.Notifications.NotificationHandlersTest do
  @moduledoc """
      Tests for GroupInvitationHandler, OfferNotificationHandler, and
      WishlistAvailabilityHandler.
  """

  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Notifications.GroupInvitationHandler
  alias Stacks.Notifications.OfferNotificationHandler
  alias Stacks.Notifications.WishlistAvailabilityHandler
  alias Stacks.Workers.EmailDeliveryJob

  describe "GroupInvitationHandler.handle_event/1" do
    test "enqueues group_invitation email when notify_group_invitations is true" do
      user = insert(:user, notify_group_invitations: true)
      inviter = insert(:user)
      invitation_id = Ecto.UUID.generate()

      # ⚠️ The shape `Social.invite_to_group/3` ACTUALLY emits. The previous
      # version of this test invented `invitee_id`/`inviter_name`/`group_name`,
      # none of which the emitter sets — so it passed against a handler that
      # resolved every key to nil and sent nothing, for as long as it existed.
      assert :ok =
               GroupInvitationHandler.handle_event(%{
                 event_type: "group.invitation_sent",
                 aggregate_id: Ecto.UUID.generate(),
                 payload: %{
                   "invited_user_id" => user.id,
                   "invited_by_id" => inviter.id,
                   "invitation_id" => invitation_id
                 }
               })

      assert_enqueued(
        worker: EmailDeliveryJob,
        args: %{"template" => "group_invitation", "user_id" => user.id}
      )
    end

    test "does not enqueue when notify_group_invitations is false" do
      user = insert(:user, notify_group_invitations: false)

      assert :ok =
               GroupInvitationHandler.handle_event(%{
                 event_type: "group.invitation_sent",
                 aggregate_id: Ecto.UUID.generate(),
                 payload: %{
                   "invited_user_id" => user.id,
                   "invited_by_id" => Ecto.UUID.generate(),
                   "invitation_id" => Ecto.UUID.generate()
                 }
               })

      refute_enqueued(worker: EmailDeliveryJob)
    end

    test "returns :ok and does not crash when invitee does not exist" do
      assert :ok =
               GroupInvitationHandler.handle_event(%{
                 event_type: "group.invitation_sent",
                 aggregate_id: Ecto.UUID.generate(),
                 payload: %{
                   "invited_user_id" => Ecto.UUID.generate(),
                   "invited_by_id" => Ecto.UUID.generate(),
                   "invitation_id" => Ecto.UUID.generate()
                 }
               })

      refute_enqueued(worker: EmailDeliveryJob)
    end

    test "ignores unrelated event types" do
      assert :ok = GroupInvitationHandler.handle_event(%{event_type: "some.other.event"})
      refute_enqueued(worker: EmailDeliveryJob)
    end
  end

  describe "OfferNotificationHandler.handle_event/1" do
    test "enqueues new_offer email to seller when notify_marketplace is true" do
      seller = insert(:user, notify_marketplace: true)
      book = insert(:book)
      listing = insert(:listing, seller: seller, book: book, status: "active")

      assert :ok =
               OfferNotificationHandler.handle_event(%{
                 event_type: "offer.opened",
                 payload: %{
                   "listing_id" => listing.id,
                   "buyer_name" => "Bob",
                   "offer_amount_zar" => "150.00",
                   "offer_id" => Ecto.UUID.generate()
                 }
               })

      assert_enqueued(
        worker: EmailDeliveryJob,
        args: %{"template" => "new_offer", "user_id" => seller.id}
      )
    end

    test "does not enqueue when seller notify_marketplace is false" do
      seller = insert(:user, notify_marketplace: false)
      book = insert(:book)
      listing = insert(:listing, seller: seller, book: book, status: "active")

      assert :ok =
               OfferNotificationHandler.handle_event(%{
                 event_type: "offer.opened",
                 payload: %{
                   "listing_id" => listing.id,
                   "buyer_name" => "Bob",
                   "offer_amount_zar" => "150.00",
                   "offer_id" => Ecto.UUID.generate()
                 }
               })

      refute_enqueued(worker: EmailDeliveryJob)
    end

    test "returns :ok and does not crash when listing does not exist" do
      assert :ok =
               OfferNotificationHandler.handle_event(%{
                 event_type: "offer.opened",
                 payload: %{
                   "listing_id" => Ecto.UUID.generate(),
                   "buyer_name" => "Bob",
                   "offer_amount_zar" => "150.00",
                   "offer_id" => Ecto.UUID.generate()
                 }
               })

      refute_enqueued(worker: EmailDeliveryJob)
    end

    test "ignores unrelated event types" do
      assert :ok = OfferNotificationHandler.handle_event(%{event_type: "some.other.event"})
      refute_enqueued(worker: EmailDeliveryJob)
    end
  end

  describe "WishlistAvailabilityHandler.handle_event/1" do
    test "enqueues wishlist_available email for each user with book wishlisted" do
      book = insert(:book)
      user = insert(:user, notify_wishlist_availability: true)
      seller = insert(:user)
      listing = insert(:listing, book: book, seller: seller, status: "active")

      wishlist = insert(:bookshelf, user: user, name: "wishlist")
      insert(:placement, book: book, bookshelf: wishlist)

      assert :ok =
               WishlistAvailabilityHandler.handle_event(%{
                 event_type: "listing.activated",
                 aggregate_id: listing.id,
                 payload: %{"book_id" => book.id, "seller_id" => seller.id}
               })

      assert_enqueued(
        worker: EmailDeliveryJob,
        args: %{"template" => "wishlist_available", "user_id" => user.id}
      )
    end

    test "does not enqueue for users with notify_wishlist_availability false" do
      book = insert(:book)
      user = insert(:user, notify_wishlist_availability: false)
      seller = insert(:user)
      listing = insert(:listing, book: book, seller: seller, status: "active")

      wishlist = insert(:bookshelf, user: user, name: "wishlist")
      insert(:placement, book: book, bookshelf: wishlist)

      assert :ok =
               WishlistAvailabilityHandler.handle_event(%{
                 event_type: "listing.activated",
                 aggregate_id: listing.id,
                 payload: %{"book_id" => book.id, "seller_id" => seller.id}
               })

      refute_enqueued(worker: EmailDeliveryJob)
    end

    test "returns :ok and does not crash when listing does not exist" do
      assert :ok =
               WishlistAvailabilityHandler.handle_event(%{
                 event_type: "listing.activated",
                 aggregate_id: Ecto.UUID.generate(),
                 payload: %{}
               })

      refute_enqueued(worker: EmailDeliveryJob)
    end

    test "deduplicates: second handle_event for same book+user within 24h enqueues only one job" do
      book = insert(:book)
      user = insert(:user, notify_wishlist_availability: true)
      seller = insert(:user)
      listing = insert(:listing, book: book, seller: seller, status: "active")

      wishlist = insert(:bookshelf, user: user, name: "wishlist")
      insert(:placement, book: book, bookshelf: wishlist)

      event = %{event_type: "listing.activated", aggregate_id: listing.id, payload: %{}}

      assert :ok = WishlistAvailabilityHandler.handle_event(event)
      assert :ok = WishlistAvailabilityHandler.handle_event(event)

      assert [_single_job] =
               all_enqueued(
                 worker: EmailDeliveryJob,
                 args: %{"template" => "wishlist_available", "user_id" => user.id}
               )
    end

    test "ignores unrelated event types" do
      assert :ok = WishlistAvailabilityHandler.handle_event(%{event_type: "some.other.event"})
      refute_enqueued(worker: EmailDeliveryJob)
    end
  end
end
