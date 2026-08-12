defmodule Stacks.DiscoveryTest do
  @moduledoc "Tests for the Stacks.Discovery context."

  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Discovery
  alias Stacks.Enrichment.DiscoveredSource

  describe "create_source/1" do
    test "creates a source with pending_review status" do
      attrs = %{
        name: "Test Bookshop",
        type: "bookshop",
        url: "https://testbookshop.com"
      }

      assert {:ok, %DiscoveredSource{} = source} = Discovery.create_source(attrs)
      assert source.name == "Test Bookshop"
      assert source.type == "bookshop"
      assert source.url == "https://testbookshop.com"
      assert source.status == "pending_review"
      assert source.discovered_at != nil
    end

    test "returns error on duplicate URL" do
      insert(:discovered_source, url: "https://dupe.com")

      attrs = %{
        name: "Duplicate",
        type: "bookshop",
        url: "https://dupe.com"
      }

      assert {:error, :duplicate} = Discovery.create_source(attrs)
    end

    test "validates required fields" do
      assert {:error, changeset} = Discovery.create_source(%{})
      errors = errors_on(changeset)
      assert "can't be blank" in errors[:name]
      assert "can't be blank" in errors[:type]
      assert "can't be blank" in errors[:url]
    end

    test "validates type inclusion" do
      attrs = %{
        name: "Bad Type",
        type: "invalid_type",
        url: "https://badtype.com"
      }

      assert {:error, changeset} = Discovery.create_source(attrs)
      errors = errors_on(changeset)
      assert "is invalid" in errors[:type]
    end
  end

  describe "get_source_by_url/1" do
    test "returns the source matching the URL" do
      source = insert(:discovered_source, url: "https://findme.com")
      found = Discovery.get_source_by_url("https://findme.com")
      assert found.id == source.id
    end

    test "returns nil when URL not found" do
      assert is_nil(Discovery.get_source_by_url("https://doesnotexist.com"))
    end
  end

  describe "get_source/1" do
    test "returns source by ID" do
      source = insert(:discovered_source)
      found = Discovery.get_source(source.id)
      assert found.id == source.id
    end

    test "returns nil when ID not found" do
      assert is_nil(Discovery.get_source(Ecto.UUID.generate()))
    end
  end

  describe "pending_sources/0" do
    test "returns only sources with pending_review status" do
      _approved = insert(:discovered_source, status: "approved")
      pending = insert(:discovered_source, status: "pending_review")

      results = Discovery.pending_sources()
      assert length(results) == 1
      assert hd(results).id == pending.id
    end
  end

  describe "sources_for_location/2" do
    test "returns approved sources matching city" do
      insert(:discovered_source,
        status: "approved",
        discovered_via: "search:bookshops location:Cape Town,ZA"
      )

      insert(:discovered_source,
        status: "approved",
        discovered_via: "search:bookshops location:Johannesburg,ZA"
      )

      results = Discovery.sources_for_location("Cape Town", nil)
      assert length(results) == 1
    end

    test "returns approved sources matching country code" do
      insert(:discovered_source,
        status: "approved",
        discovered_via: "search:bookshops location:Cape Town,ZA"
      )

      insert(:discovered_source,
        status: "approved",
        discovered_via: "search:bookshops location:London,GB"
      )

      results = Discovery.sources_for_location(nil, "ZA")
      assert length(results) == 1
    end

    test "excludes non-approved sources" do
      insert(:discovered_source,
        status: "pending_review",
        discovered_via: "search:bookshops location:Cape Town,ZA"
      )

      results = Discovery.sources_for_location("Cape Town", nil)
      assert results == []
    end
  end

  describe "update_source_status/2" do
    test "updates status to approved" do
      source = insert(:discovered_source, status: "pending_review")
      now = DateTime.utc_now()

      assert {:ok, updated} =
               Discovery.update_source_status(source, %{status: "approved", approved_at: now})

      assert updated.status == "approved"
      assert updated.approved_at != nil
    end

    test "updates status to dismissed" do
      source = insert(:discovered_source, status: "pending_review")
      assert {:ok, updated} = Discovery.update_source_status(source, %{status: "dismissed"})
      assert updated.status == "dismissed"
    end
  end

  describe "update_confidence/2" do
    test "updates the confidence score" do
      source = insert(:discovered_source)
      assert {:ok, updated} = Discovery.update_confidence(source, 0.85)
      assert updated.confidence == 0.85
    end

    test "rejects confidence out of range" do
      source = insert(:discovered_source)
      assert {:error, changeset} = Discovery.update_confidence(source, 1.5)
      errors = errors_on(changeset)
      assert errors[:confidence] != nil
    end
  end

  describe "opt_out/2" do
    test "removes the listing when the requester's domain matches it" do
      _source = insert(:discovered_source, url: "https://optout.com", status: "pending_review")

      assert {:ok, :excluded, updated} =
               Discovery.opt_out("https://optout.com", %{email: "owner@optout.com"})

      assert updated.status == "excluded"
      assert updated.exclusion_email == "owner@optout.com"
      assert updated.excluded_at != nil
      assert updated.exclusion_requested_at != nil
    end

    test "does NOT remove the listing when the domain does not match" do
      insert(:discovered_source, url: "https://booklounge.co.za", status: "approved")

      assert {:ok, :pending_review, updated} =
               Discovery.opt_out("https://booklounge.co.za", %{email: "randomer@gmail.com"})

      assert updated.status == "approved", "the listing must stay live until reviewed"
      assert updated.excluded_at == nil
      assert updated.exclusion_requested_at != nil, "but the request must be visible"
      assert updated.exclusion_email == "randomer@gmail.com"
    end

    test "a www prefix or a deep path does not defeat a legitimate request" do
      insert(:discovered_source, url: "https://www.booklounge.co.za/about-us", status: "approved")

      assert {:ok, :excluded, _} =
               Discovery.opt_out("https://www.booklounge.co.za/about-us", %{
                 email: "hello@booklounge.co.za"
               })
    end

    test "handles multi-part public suffixes" do
      insert(:discovered_source, url: "https://clarkesbooks.co.za", status: "approved")

      assert {:ok, :pending_review, _} =
               Discovery.opt_out("https://clarkesbooks.co.za", %{
                 email: "someone@wordsworth.co.za"
               })
    end

    test "a subdomain of the listed domain still counts as the business" do
      insert(:discovered_source, url: "https://shop.bridgebooks.co.za", status: "approved")

      assert {:ok, :excluded, _} =
               Discovery.opt_out("https://shop.bridgebooks.co.za", %{
                 email: "owner@bridgebooks.co.za"
               })
    end

    test "returns not_found for unknown URL" do
      assert {:error, :not_found} =
               Discovery.opt_out("https://unknown.com", %{email: "test@test.com"})
    end

    test "returns invalid_email for bad email" do
      insert(:discovered_source, url: "https://bademail.com")

      assert {:error, :invalid_email} =
               Discovery.opt_out("https://bademail.com", %{email: "notanemail"})
    end
  end
end
