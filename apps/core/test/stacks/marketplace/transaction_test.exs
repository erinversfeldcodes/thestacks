defmodule Stacks.Marketplace.TransactionTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Marketplace
  alias Stacks.Marketplace.Transaction

  describe "transaction_changeset/2" do
    test "is valid with required fields" do
      listing = insert(:listing)

      changeset =
        Marketplace.transaction_changeset(%Transaction{}, %{
          listing_id: listing.id,
          amount_cents: 15_000,
          payment_status: "pending"
        })

      assert changeset.valid?
    end

    test "is invalid without listing_id" do
      changeset =
        Marketplace.transaction_changeset(%Transaction{}, %{
          amount_cents: 15_000,
          payment_status: "pending"
        })

      refute changeset.valid?
      assert %{listing_id: [_ | _]} = errors_on(changeset)
    end

    test "is invalid without amount_cents" do
      changeset =
        Marketplace.transaction_changeset(%Transaction{}, %{
          listing_id: Ecto.UUID.generate(),
          payment_status: "pending"
        })

      refute changeset.valid?
      assert %{amount_cents: [_ | _]} = errors_on(changeset)
    end

    test "is invalid with an unknown payment_status" do
      changeset =
        Marketplace.transaction_changeset(%Transaction{}, %{
          listing_id: Ecto.UUID.generate(),
          amount_cents: 15_000,
          payment_status: "disputed"
        })

      refute changeset.valid?
      assert %{payment_status: [_ | _]} = errors_on(changeset)
    end

    test "accepts all valid payment_statuses" do
      for status <- ~w(pending paid failed refunded) do
        changeset =
          Marketplace.transaction_changeset(%Transaction{}, %{
            listing_id: Ecto.UUID.generate(),
            amount_cents: 15_000,
            payment_status: status
          })

        assert changeset.valid?, "expected valid for payment_status=#{status}"
      end
    end

    test "is invalid with an unknown shipping_status" do
      changeset =
        Marketplace.transaction_changeset(%Transaction{}, %{
          listing_id: Ecto.UUID.generate(),
          amount_cents: 15_000,
          payment_status: "pending",
          shipping_status: "teleported"
        })

      refute changeset.valid?
      assert %{shipping_status: [_ | _]} = errors_on(changeset)
    end

    test "accepts all valid shipping_statuses" do
      for status <- ~w(pending shipped delivered returned) do
        changeset =
          Marketplace.transaction_changeset(%Transaction{}, %{
            listing_id: Ecto.UUID.generate(),
            amount_cents: 15_000,
            payment_status: "pending",
            shipping_status: status
          })

        assert changeset.valid?, "expected valid for shipping_status=#{status}"
      end
    end

    test "allows nil shipping_status" do
      changeset =
        Marketplace.transaction_changeset(%Transaction{}, %{
          listing_id: Ecto.UUID.generate(),
          amount_cents: 15_000,
          payment_status: "pending"
        })

      assert changeset.valid?
      assert get_change(changeset, :shipping_status) == nil
    end
  end

  describe "DB constraint smoke test" do
    test "persists a valid transaction" do
      txn = insert(:transaction)
      assert txn.id
      assert txn.payment_status == "pending"
    end

    test "allows nil buyer_id and seller_id (GDPR erasure pattern)" do
      listing = insert(:listing)

      {:ok, txn} =
        %Transaction{}
        |> Marketplace.transaction_changeset(%{
          listing_id: listing.id,
          amount_cents: 10_000,
          payment_status: "paid"
        })
        |> Core.Repo.insert()

      assert txn.buyer_id == nil
      assert txn.seller_id == nil
    end
  end
end
