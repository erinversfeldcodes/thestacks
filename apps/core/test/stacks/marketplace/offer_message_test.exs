defmodule Stacks.Marketplace.OfferMessageTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Marketplace
  alias Stacks.Marketplace.OfferMessage

  describe "offer_message_changeset/2" do
    test "is valid with required fields" do
      thread = insert(:offer_thread)
      sender = insert(:user)

      changeset =
        Marketplace.offer_message_changeset(%OfferMessage{}, %{
          thread_id: thread.id,
          sender_id: sender.id,
          type: "message",
          body: "Is this still available?"
        })

      assert changeset.valid?
    end

    test "is invalid without thread_id" do
      changeset =
        Marketplace.offer_message_changeset(%OfferMessage{}, %{
          sender_id: Ecto.UUID.generate(),
          type: "message"
        })

      refute changeset.valid?
      assert %{thread_id: [_ | _]} = errors_on(changeset)
    end

    test "is invalid without sender_id" do
      changeset =
        Marketplace.offer_message_changeset(%OfferMessage{}, %{
          thread_id: Ecto.UUID.generate(),
          type: "message"
        })

      refute changeset.valid?
      assert %{sender_id: [_ | _]} = errors_on(changeset)
    end

    test "is invalid without type" do
      changeset =
        Marketplace.offer_message_changeset(%OfferMessage{}, %{
          thread_id: Ecto.UUID.generate(),
          sender_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert %{type: [_ | _]} = errors_on(changeset)
    end

    test "is invalid with an unknown type" do
      changeset =
        Marketplace.offer_message_changeset(%OfferMessage{}, %{
          thread_id: Ecto.UUID.generate(),
          sender_id: Ecto.UUID.generate(),
          type: "sticker"
        })

      refute changeset.valid?
      assert %{type: [_ | _]} = errors_on(changeset)
    end

    test "accepts all valid types" do
      for type <- ~w(message offer counter accept decline) do
        changeset =
          Marketplace.offer_message_changeset(%OfferMessage{}, %{
            thread_id: Ecto.UUID.generate(),
            sender_id: Ecto.UUID.generate(),
            type: type
          })

        assert changeset.valid?, "expected valid for type=#{type}"
      end
    end

    test "allows nil amount_cents for non-offer messages" do
      changeset =
        Marketplace.offer_message_changeset(%OfferMessage{}, %{
          thread_id: Ecto.UUID.generate(),
          sender_id: Ecto.UUID.generate(),
          type: "message",
          body: "Hello"
        })

      assert changeset.valid?
      assert get_change(changeset, :amount_cents) == nil
    end
  end

  describe "DB constraint smoke test" do
    test "persists a valid offer message" do
      message = insert(:offer_message)
      assert message.id
      assert message.type == "message"
    end
  end
end
