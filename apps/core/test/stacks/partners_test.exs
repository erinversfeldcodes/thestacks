defmodule Stacks.PartnersTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Partners

  @valid_attrs %{
    name: "The Reading Room",
    business_type: "bookshop",
    contact_email: "hello@readingroom.com"
  }

  describe "register_partner/1" do
    test "creates a pending partner" do
      assert {:ok, partner} = Partners.register_partner(@valid_attrs)
      assert partner.status == "pending"
      assert partner.name == "The Reading Room"
    end

    test "returns error for missing required fields" do
      assert {:error, changeset} = Partners.register_partner(%{})
      assert changeset.errors[:name]
    end

    test "returns error for invalid business_type" do
      assert {:error, changeset} =
               Partners.register_partner(Map.put(@valid_attrs, :business_type, "invalid"))

      assert changeset.errors[:business_type]
    end

    test "returns error for duplicate contact_email" do
      Partners.register_partner(@valid_attrs)
      assert {:error, changeset} = Partners.register_partner(@valid_attrs)
      assert changeset.errors[:contact_email]
    end
  end

  describe "approve_partner/2" do
    test "returns raw key and updates status to approved" do
      {:ok, partner} = Partners.register_partner(@valid_attrs)
      admin = insert(:user)

      assert {:ok, {approved, raw_key}} = Partners.approve_partner(partner.id, admin.id)
      assert approved.status == "approved"
      assert String.starts_with?(raw_key, "stacks_pk_")
      assert String.length(raw_key) == 74
    end

    test "key can authenticate partner" do
      {:ok, partner} = Partners.register_partner(@valid_attrs)
      admin = insert(:user)
      {:ok, {_, raw_key}} = Partners.approve_partner(partner.id, admin.id)

      assert {:ok, authenticated} = Partners.authenticate_partner(raw_key)
      assert authenticated.id == partner.id
    end

    test "returns :already_approved for second approval" do
      {:ok, partner} = Partners.register_partner(@valid_attrs)
      admin = insert(:user)
      Partners.approve_partner(partner.id, admin.id)

      assert {:error, :already_approved} = Partners.approve_partner(partner.id, admin.id)
    end

    test "returns :not_found for missing partner" do
      assert {:error, :not_found} = Partners.approve_partner(Ecto.UUID.generate(), "any")
    end
  end

  describe "rotate_key/1" do
    test "new key works, old key does not" do
      {:ok, partner} = Partners.register_partner(@valid_attrs)
      admin = insert(:user)
      {:ok, {_, old_key}} = Partners.approve_partner(partner.id, admin.id)
      {:ok, new_key} = Partners.rotate_key(partner.id)

      assert {:ok, _} = Partners.authenticate_partner(new_key)
      assert {:error, :invalid} = Partners.authenticate_partner(old_key)
    end

    test "returns :not_found for missing partner" do
      assert {:error, :not_found} = Partners.rotate_key(Ecto.UUID.generate())
    end
  end

  describe "authenticate_partner/1" do
    test "returns :invalid for wrong key" do
      {:ok, partner} = Partners.register_partner(@valid_attrs)
      admin = insert(:user)
      Partners.approve_partner(partner.id, admin.id)

      assert {:error, :invalid} =
               Partners.authenticate_partner("stacks_pk_" <> String.duplicate("0", 40))
    end

    test "returns :invalid for non-existent prefix" do
      assert {:error, :invalid} =
               Partners.authenticate_partner("stacks_pk_" <> String.duplicate("f", 40))
    end
  end

  describe "reject_partner/3" do
    test "sets status to rejected" do
      {:ok, partner} = Partners.register_partner(@valid_attrs)
      admin = insert(:user)

      assert {:ok, rejected} = Partners.reject_partner(partner.id, admin.id, "Not suitable")
      assert rejected.status == "rejected"
    end
  end

  describe "list_pending_partners/0" do
    test "returns only pending partners" do
      {:ok, _p1} = Partners.register_partner(@valid_attrs)

      {:ok, p2} =
        Partners.register_partner(Map.put(@valid_attrs, :contact_email, "other@example.com"))

      admin = insert(:user)
      Partners.approve_partner(p2.id, admin.id)

      pending = Partners.list_pending_partners()
      assert length(pending) == 1
      assert hd(pending).contact_email == "hello@readingroom.com"
    end
  end
end
