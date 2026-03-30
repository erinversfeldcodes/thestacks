defmodule Stacks.EnrichmentThirdSpacesTest do
  @moduledoc """
  Tests for Stacks.Enrichment.list_third_spaces/1 and
  Stacks.Enrichment.book_availability/1.
  """

  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Enrichment

  describe "list_third_spaces/1" do
    test "returns all spaces when no geo params provided" do
      insert(:third_space, name: "The Book Lounge")
      insert(:third_space, name: "Cafe Fynbos")

      result = Enrichment.list_third_spaces()

      names = Enum.map(result, & &1.name)
      assert "The Book Lounge" in names
      assert "Cafe Fynbos" in names
      assert length(result) == 2
    end

    test "preloads upcoming events for each space" do
      space = insert(:third_space, name: "The Book Lounge")
      future_date = DateTime.add(DateTime.utc_now(), 7, :day)

      insert(:third_space_event,
        space: space,
        title: "Poetry Night",
        event_date: future_date,
        scraped_at: DateTime.utc_now()
      )

      [returned_space] = Enrichment.list_third_spaces()

      assert length(returned_space.upcoming_events) == 1
      assert hd(returned_space.upcoming_events).title == "Poetry Night"
    end

    test "does NOT include past events in upcoming_events" do
      space = insert(:third_space, name: "The Book Lounge")
      past_date = DateTime.add(DateTime.utc_now(), -7, :day)
      future_date = DateTime.add(DateTime.utc_now(), 7, :day)

      insert(:third_space_event,
        space: space,
        title: "Past Event",
        event_date: past_date,
        scraped_at: DateTime.utc_now()
      )

      insert(:third_space_event,
        space: space,
        title: "Future Event",
        event_date: future_date,
        scraped_at: DateTime.utc_now()
      )

      [returned_space] = Enrichment.list_third_spaces()

      event_titles = Enum.map(returned_space.upcoming_events, & &1.title)
      assert "Future Event" in event_titles
      refute "Past Event" in event_titles
    end

    test "with geo params returns only spaces within radius" do
      # Cape Town city center: approx -33.9249, 18.4241
      insert(:third_space, name: "Nearby Cafe", city: "Cape Town")
      # Johannesburg: approx -26.2041, 28.0473 (~1270 km away)
      insert(:third_space, name: "Far Away Shop", city: "Johannesburg")

      result =
        Enrichment.list_third_spaces(
          lat: -33.9249,
          lng: 18.4241,
          radius_km: 50
        )

      names = Enum.map(result, & &1.name)
      assert "Nearby Cafe" in names
      refute "Far Away Shop" in names
    end
  end

  describe "book_availability/1" do
    test "returns inventory for a book with quantity > 0" do
      book = insert(:book, title: "Middlemarch")
      edition = insert(:book_edition, book: book, isbn: "9780141439549")

      partner =
        insert(:partner,
          name: "The Corner Bookshop",
          status: "approved",
          approved_at: DateTime.utc_now()
        )

      insert(:partner_inventory_item,
        partner: partner,
        book_edition: edition,
        price_cents: 15_000,
        condition: "good",
        quantity: 3
      )

      result = Enrichment.book_availability(book.id)

      assert length(result) == 1
      item = hd(result)
      assert item.price_cents == 15_000
      assert item.condition == "good"
      assert item.quantity == 3
    end

    test "excludes items with quantity = 0" do
      book = insert(:book, title: "Silas Marner")
      edition = insert(:book_edition, book: book, isbn: "9780141439747")

      partner =
        insert(:partner,
          name: "The Corner Bookshop",
          status: "approved",
          approved_at: DateTime.utc_now()
        )

      insert(:partner_inventory_item,
        partner: partner,
        book_edition: edition,
        price_cents: 10_000,
        condition: "good",
        quantity: 0
      )

      result = Enrichment.book_availability(book.id)
      assert result == []
    end

    test "excludes unapproved partners" do
      book = insert(:book, title: "Daniel Deronda")
      edition = insert(:book_edition, book: book, isbn: "9780140434279")

      pending_partner = insert(:partner, name: "Pending Shop", status: "pending")

      insert(:partner_inventory_item,
        partner: pending_partner,
        book_edition: edition,
        price_cents: 12_000,
        condition: "good",
        quantity: 5
      )

      result = Enrichment.book_availability(book.id)
      assert result == []
    end

    test "returns empty list when no stock exists" do
      book = insert(:book, title: "The Mill on the Floss")
      result = Enrichment.book_availability(book.id)
      assert result == []
    end
  end
end
