defmodule Stacks.Marketplace.OfferThreadTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Marketplace
  alias Stacks.Marketplace.OfferThread

  describe "offer_thread_changeset/2" do
    test "is valid with required fields" do
      placement = insert(:placement)
      buyer = insert(:user)

      changeset =
        Marketplace.offer_thread_changeset(%OfferThread{}, %{
          placement_id: placement.id,
          buyer_id: buyer.id
        })

      assert changeset.valid?
    end

    test "is invalid without placement_id" do
      changeset =
        Marketplace.offer_thread_changeset(%OfferThread{}, %{buyer_id: Ecto.UUID.generate()})

      refute changeset.valid?
      assert %{placement_id: [_ | _]} = errors_on(changeset)
    end

    test "is invalid without buyer_id" do
      changeset =
        Marketplace.offer_thread_changeset(%OfferThread{}, %{placement_id: Ecto.UUID.generate()})

      refute changeset.valid?
      assert %{buyer_id: [_ | _]} = errors_on(changeset)
    end

    test "is invalid with an unknown status" do
      changeset =
        Marketplace.offer_thread_changeset(%OfferThread{}, %{
          placement_id: Ecto.UUID.generate(),
          buyer_id: Ecto.UUID.generate(),
          status: "ghosted"
        })

      refute changeset.valid?
      assert %{status: [_ | _]} = errors_on(changeset)
    end

    test "accepts all valid statuses" do
      for status <- ~w(open accepted declined expired) do
        changeset =
          Marketplace.offer_thread_changeset(%OfferThread{}, %{
            placement_id: Ecto.UUID.generate(),
            buyer_id: Ecto.UUID.generate(),
            status: status
          })

        assert changeset.valid?, "expected valid for status=#{status}"
      end
    end
  end

  describe "DB constraint smoke test" do
    test "persists a valid offer thread" do
      thread = insert(:offer_thread)
      assert thread.id
      assert thread.status == "open"
    end

    test "enforces unique constraint on placement_id + buyer_id" do
      placement = insert(:placement)
      buyer = insert(:user)
      insert(:offer_thread, placement: placement, buyer: buyer)

      assert {:error, changeset} =
               %OfferThread{}
               |> Marketplace.offer_thread_changeset(%{
                 placement_id: placement.id,
                 buyer_id: buyer.id
               })
               |> Core.Repo.insert()

      assert %{placement_id: [_ | _]} = errors_on(changeset)
    end
  end
end
