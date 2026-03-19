defmodule Stacks.Marketplace.ListingTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Marketplace.Listing

  describe "changeset/2" do
    test "is valid with all required fields" do
      book = insert(:book)
      seller = insert(:user)

      changeset =
        Listing.changeset(%Listing{}, %{
          book_id: book.id,
          seller_id: seller.id,
          status: "draft",
          pricing_mode: "fixed",
          price_cents: 15_000,
          currency: "ZAR",
          condition: "good",
          description: "Good condition."
        })

      assert changeset.valid?
    end

    test "is invalid without price_cents" do
      book = insert(:book)
      seller = insert(:user)

      changeset =
        Listing.changeset(%Listing{}, %{
          book_id: book.id,
          seller_id: seller.id,
          status: "draft",
          pricing_mode: "fixed",
          currency: "ZAR",
          condition: "good",
          description: "Good condition."
        })

      refute changeset.valid?
      assert %{price_cents: [_ | _]} = errors_on(changeset)
    end

    test "is invalid with an unknown status" do
      book = insert(:book)
      seller = insert(:user)

      changeset =
        Listing.changeset(%Listing{}, %{
          book_id: book.id,
          seller_id: seller.id,
          status: "limbo",
          pricing_mode: "fixed",
          price_cents: 15_000,
          currency: "ZAR",
          condition: "good",
          description: "Good condition."
        })

      refute changeset.valid?
      assert %{status: [_ | _]} = errors_on(changeset)
    end

    test "is invalid with an unknown condition" do
      book = insert(:book)
      seller = insert(:user)

      changeset =
        Listing.changeset(%Listing{}, %{
          book_id: book.id,
          seller_id: seller.id,
          status: "draft",
          pricing_mode: "fixed",
          price_cents: 15_000,
          currency: "ZAR",
          condition: "destroyed",
          description: "Ruined."
        })

      refute changeset.valid?
      assert %{condition: [_ | _]} = errors_on(changeset)
    end

    test "is invalid with an unknown pricing_mode" do
      book = insert(:book)
      seller = insert(:user)

      changeset =
        Listing.changeset(%Listing{}, %{
          book_id: book.id,
          seller_id: seller.id,
          status: "draft",
          pricing_mode: "haggle",
          price_cents: 15_000,
          currency: "ZAR",
          condition: "good",
          description: "Good condition."
        })

      refute changeset.valid?
      assert %{pricing_mode: [_ | _]} = errors_on(changeset)
    end
  end
end
