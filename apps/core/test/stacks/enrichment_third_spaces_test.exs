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
      insert(:third_space, name: "Nearby Cafe", latitude: -33.9249, longitude: 18.4241)
      insert(:third_space, name: "Far Away Shop", latitude: -26.2041, longitude: 28.0473)

      result = Enrichment.list_third_spaces(lat: -33.9249, lng: 18.4241, radius_km: 50)

      names = Enum.map(result, & &1.name)
      assert "Nearby Cafe" in names
      refute "Far Away Shop" in names
    end

    test "distinguishes two spaces in the same city" do
      insert(:third_space, name: "Around The Corner", latitude: -33.9249, longitude: 18.4262)
      insert(:third_space, name: "Across The Peninsula", latitude: -34.1350, longitude: 18.4270)

      names =
        Enrichment.list_third_spaces(lat: -33.9249, lng: 18.4241, radius_km: 1)
        |> Enum.map(& &1.name)

      assert "Around The Corner" in names
      refute "Across The Peninsula" in names
    end

    test "applies the limit AFTER the radius refinement, not before" do
      corner_lat = -33.9249 + 0.045 * 0.98
      corner_lng = 18.4241 + 0.0543 * 0.98

      for i <- 1..6 do
        insert(:third_space, name: "AAA Corner #{i}", latitude: corner_lat, longitude: corner_lng)
      end

      insert(:third_space, name: "ZZZ The Near One", latitude: -33.9249, longitude: 18.4241)

      names =
        Enrichment.list_third_spaces(lat: -33.9249, lng: 18.4241, radius_km: 5, limit: 5)
        |> Enum.map(& &1.name)

      assert "ZZZ The Near One" in names,
             "the nearest space was excluded — the limit is being applied before the " <>
               "radius refinement, so box corners consumed the budget"

      refute Enum.any?(names, &String.starts_with?(&1, "AAA Corner")),
             "a box-corner space survived the radius refinement"
    end

    test "excludes a space that has opted out" do
      insert(:third_space, name: "Still Listed")
      insert(:third_space, name: "Asked To Be Removed", opted_out: true)

      names = Enrichment.list_third_spaces() |> Enum.map(& &1.name)

      assert "Still Listed" in names
      refute "Asked To Be Removed" in names
    end

    test "a space with no coordinates is excluded from a geo query, not guessed at" do
      insert(:third_space, name: "Unpositioned", latitude: nil, longitude: nil)

      names =
        Enrichment.list_third_spaces(lat: -33.9249, lng: 18.4241, radius_km: 5000)
        |> Enum.map(& &1.name)

      refute "Unpositioned" in names
    end
  end

  describe "list_third_spaces/1 — viewport and filters (US-3.1.1)" do
    test "returns spaces inside a viewport" do
      insert(:third_space, name: "In View", latitude: -33.92, longitude: 18.42)
      insert(:third_space, name: "Out Of View", latitude: -26.20, longitude: 28.04)

      names =
        Enrichment.list_third_spaces(north: -33.90, south: -33.95, west: 18.40, east: 18.45)
        |> Enum.map(& &1.name)

      assert "In View" in names
      refute "Out Of View" in names
    end

    test "a viewport crossing the antimeridian still returns results" do
      insert(:third_space, name: "Just West of the Line", latitude: -17.0, longitude: 179.0)
      insert(:third_space, name: "Just East of the Line", latitude: -17.0, longitude: -179.0)
      insert(:third_space, name: "Nowhere Near", latitude: -17.0, longitude: 0.0)

      names =
        Enrichment.list_third_spaces(north: -16.0, south: -18.0, west: 178.0, east: -178.0)
        |> Enum.map(& &1.name)

      assert "Just West of the Line" in names,
             "the antimeridian viewport returned nothing — the two-box case is missing"

      assert "Just East of the Line" in names
      refute "Nowhere Near" in names
    end

    test "near_bookshop_km filters on the precomputed distance" do
      insert(:third_space, name: "By A Bookshop", nearest_bookshop_km: 0.3)
      insert(:third_space, name: "Miles From Books", nearest_bookshop_km: 12.0)

      names =
        Enrichment.list_third_spaces(near_bookshop_km: 0.5) |> Enum.map(& &1.name)

      assert "By A Bookshop" in names
      refute "Miles From Books" in names
    end

    test "a curated space just beyond the radius is included — 500 m is a rule of thumb" do
      insert(:third_space, name: "Truth Coffee", nearest_bookshop_km: 0.678, curated: true)

      names = Enrichment.list_third_spaces(near_bookshop_km: 0.5) |> Enum.map(& &1.name)

      assert "Truth Coffee" in names,
             "a curated space 678 m out was excluded — the rule is still a hard cutoff"
    end

    test "an uncurated space just beyond the radius stays out" do
      insert(:third_space, name: "Ordinary Cafe", nearest_bookshop_km: 0.678, curated: false)

      names = Enrichment.list_third_spaces(near_bookshop_km: 0.5) |> Enum.map(& &1.name)

      refute "Ordinary Cafe" in names
    end

    test "curated does not mean any distance" do
      assert Enrichment.curated_within_km() < 10.0,
             "the curated outer bound is too wide to mean 'near a bookshop'"

      insert(:third_space, name: "Distant Gem", nearest_bookshop_km: 40.0, curated: true)

      names = Enrichment.list_third_spaces(near_bookshop_km: 0.5) |> Enum.map(& &1.name)

      refute "Distant Gem" in names,
             "a curated space 40 km from any bookshop reached the map"
    end

    test "a space with no computed proximity is not assumed to be near a bookshop" do
      insert(:third_space, name: "Never Paired", nearest_bookshop_km: nil)

      names = Enrichment.list_third_spaces(near_bookshop_km: 0.5) |> Enum.map(& &1.name)

      refute "Never Paired" in names
    end

    test "filters by category so a reader can choose garden over pub" do
      insert(:third_space, name: "The Garden", type: "garden")
      insert(:third_space, name: "The Pub", type: "pub")

      names = Enrichment.list_third_spaces(types: ["garden"]) |> Enum.map(& &1.name)

      assert "The Garden" in names
      refute "The Pub" in names
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
