defmodule Stacks.Enrichment.EventPagesTest do
  @moduledoc """
      ⚠️ The classifier's negatives matter more than its positives, and the fixtures here are not
      invented: `@wordsworth_pages` is the shop's REAL page list from the 2026-08-04 live sitemap walk —
      45 slugs, exactly one event. A fixture written from the classifier's own assumptions would agree
      with them by construction; this list was measured before the classifier existed.
  """
  use Core.DataCase, async: true

  alias Stacks.Enrichment.EventPages
  alias Stacks.Enrichment.Events
  alias Stacks.Enrichment.MockScraperClient

  import Stacks.Factory

  setup do
    on_exit(&MockScraperClient.clear/0)
    :ok
  end

  @the_one_event "https://www.wordsworth.co.za/pages/treive-nicholas-book-signing-at-our-sea-point-store"

  @wordsworth_pages [
                      "contact-us",
                      "payment-logos",
                      "store-locator",
                      "coming-soon",
                      "bestsellers",
                      "stationary-gifts",
                      "footer-image",
                      "how-to-order",
                      "wishlist",
                      "christianity",
                      "rare-books-special-collections-request",
                      "family-holiday-recommendations",
                      "christmas-choice-2021",
                      "careers-at-wordsworth-books",
                      "branch-manager",
                      "treive-nicholas-book-signing-at-our-sea-point-store",
                      "selling-your-book-through-wordsworth",
                      "mothers-day-promotion",
                      "preorder-listing",
                      "preorder-management",
                      "bookseller",
                      "branch-manager-1",
                      "deputy-branch-manager",
                      "senior-bookseller",
                      "back-to-school-shop-save",
                      "corporate-sales-wordsworth-business",
                      "summer-sale-up-to-50-off",
                      "christmas-choice-2022",
                      "barbie",
                      "celebrate-our-birthday-with-us-chapter30",
                      "halloween",
                      "stocking-fillers",
                      "be-more-you",
                      "halloween-1",
                      "the-love-library",
                      "march-is-for-my-favourites",
                      "april-is-for-award-winners",
                      "buy-any-2-winter-warmer-titles-save-10",
                      "welcome",
                      "casual-bookseller",
                      "celebrate-heritage-month-this-september-local-is-lekker",
                      "book-of-the-month-subscription",
                      "wordsworth-books-subscriptions-terms-conditions",
                      "wordsworth-3x-months-subscription"
                    ]
                    |> Enum.map(&("https://www.wordsworth.co.za/pages/" <> &1))

  describe "event_page?/1 — against the shop's real page list" do
    test "finds exactly the one event among all 45 real pages" do
      hits = Enum.filter(@wordsworth_pages, &EventPages.event_page?/1)

      assert hits == [@the_one_event],
             "the classifier disagreed with the measured ground truth: #{inspect(hits)}"
    end

    test "every real negative is refused, each on its own line so a regression names itself" do
      for url <- @wordsworth_pages, url != @the_one_event do
        refute EventPages.event_page?(url), "invented an event from #{url}"
      end
    end

    test "each declared phrase actually classifies a slug carrying it" do
      for phrase <- EventPages.event_phrases() do
        url = "https://shop.test/pages/june-#{phrase}-with-the-author"
        assert EventPages.event_page?(url), "declared phrase #{phrase} never matches"
      end
    end

    test "the phrase must be in the SLUG, not the host or a query string" do
      refute EventPages.event_page?("https://book-signing.example.test/pages/contact-us")
      refute EventPages.event_page?("https://shop.test/pages/contact-us?from=book-signing")
    end
  end

  describe "title_of/2" do
    test "takes the page's own title and drops the shop suffix" do
      body =
        "<html><title>Treive Nicholas book signing at our Sea Point store — Wordsworth Books</title></html>"

      assert EventPages.title_of(body, @the_one_event) ==
               "Treive Nicholas book signing at our Sea Point store"
    end

    test "an em dash inside the event's own name survives" do
      body = "<html><title>Poetry — loud and live — Wordsworth Books</title></html>"

      assert EventPages.title_of(body, "https://x.test/pages/poetry-evening") ==
               "Poetry — loud and live"
    end

    test "falls back to the humanised slug rather than inventing 'Untitled'" do
      assert EventPages.title_of("<html></html>", @the_one_event) ==
               "Treive nicholas book signing at our sea point store"
    end
  end

  describe "date_of/1 — never invents a date" do
    test "the real page shape: no date anywhere yields nil" do
      assert EventPages.date_of("<html><title>An event</title><p>Join us!</p></html>") == nil
    end

    test "exactly one distinct date is used" do
      assert EventPages.date_of("<p>2026-09-14</p><p>Doors: 2026-09-14</p>") ==
               ~U[2026-09-14 00:00:00Z]
    end

    test "several different dates cannot be attributed, so none is" do
      assert EventPages.date_of("<p>2026-09-14</p><footer>2026-01-01</footer>") == nil
    end
  end

  describe "discover_and_store/2 — the chain, to a row" do
    test "the one candidate earns one fetch, is stored dateless, and the row survives" do
      store = insert(:bookstore, scraper_module: "za/test_store")

      MockScraperClient.put_page(
        "za/test_store",
        "/pages/treive-nicholas-book-signing-at-our-sea-point-store",
        {:ok,
         %{
           status: 200,
           body:
             "<html><title>Treive Nicholas book signing at our Sea Point store — Wordsworth Books</title></html>"
         }}
      )

      assert {:ok, {:events, 1}} = EventPages.discover_and_store(@wordsworth_pages, store)

      assert [{"za/test_store", "/pages/treive-nicholas-book-signing-at-our-sea-point-store"}] =
               MockScraperClient.fetches()

      assert [event] = Events.listed_events(store.id)
      assert event.title == "Treive Nicholas book signing at our Sea Point store"
      assert event.event_date == nil
      assert event.url == @the_one_event
    end

    test "the unique index treats NULLs as equal — the structural pin" do
      %{rows: [[nulls_not_distinct]]} =
        Repo.query!("""
        SELECT i.indnullsnotdistinct
        FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
        WHERE c.relname = 'bookstore_events_store_id_title_event_date_index'
        """)

      assert nulls_not_distinct,
             "the bookstore_events unique index treats NULLs as distinct — every scrape run will " <>
               "insert a fresh duplicate of each dateless event and ON CONFLICT will never fire"
    end

    test "a dateless event is upserted, not duplicated, on the second run" do
      store = insert(:bookstore, scraper_module: "za/test_store")

      MockScraperClient.put_page(
        "za/test_store",
        "/pages/treive-nicholas-book-signing-at-our-sea-point-store",
        {:ok,
         %{
           status: 200,
           body: "<html><title>Treive Nicholas book signing at our Sea Point store</title></html>"
         }}
      )

      assert {:ok, {:events, 1}} = EventPages.discover_and_store(@wordsworth_pages, store)
      assert {:ok, {:events, 1}} = EventPages.discover_and_store(@wordsworth_pages, store)

      assert length(Events.listed_events(store.id)) == 1,
             "the same dateless event was stored twice — the NULLS NOT DISTINCT index is not doing its job"
    end

    test "no candidates means no fetches and an honest :no_events_page" do
      store = insert(:bookstore, scraper_module: "za/test_store")
      negatives = Enum.reject(@wordsworth_pages, &(&1 == @the_one_event))

      assert {:ok, :no_events_page} = EventPages.discover_and_store(negatives, store)
      assert MockScraperClient.fetches() == []
    end

    test "a candidate that 404s is skipped, not stored" do
      store = insert(:bookstore, scraper_module: "za/test_store")

      MockScraperClient.put_page(
        "za/test_store",
        "/pages/treive-nicholas-book-signing-at-our-sea-point-store",
        {:ok, %{status: 404, body: ""}}
      )

      assert {:ok, :no_events_page} = EventPages.discover_and_store(@wordsworth_pages, store)
      assert Events.listed_events(store.id) == []
    end

    test "the per-run fetch cap holds, and the overflow is logged rather than silent" do
      import ExUnit.CaptureLog

      store = insert(:bookstore, scraper_module: "za/test_store")
      many = for n <- 1..8, do: "https://shop.test/pages/book-signing-#{n}"

      for n <- 1..8 do
        MockScraperClient.put_page(
          "za/test_store",
          "/pages/book-signing-#{n}",
          {:ok, %{status: 200, body: "<html><title>Signing #{n}</title></html>"}}
        )
      end

      log =
        capture_log(fn ->
          assert {:ok, {:events, 5}} = EventPages.discover_and_store(many, store)
        end)

      assert length(MockScraperClient.fetches()) == 5, "the cap did not bound the fetches"

      assert log =~ "leaving 3 for the next run",
             "the cap was silent — it reads as a complete run"
    end
  end

  describe "listed_events/1 vs upcoming_events/1 — the honesty split" do
    test "a dateless event is listed but never counted as upcoming" do
      store = insert(:bookstore)

      {:ok, _} =
        Events.upsert_event(%{
          store_id: store.id,
          title: "A signing, date on the shop's page",
          event_date: nil,
          url: "https://shop.test/pages/book-signing",
          scraped_at: DateTime.utc_now()
        })

      {:ok, _} =
        Events.upsert_event(%{
          store_id: store.id,
          title: "A dated reading",
          event_date: DateTime.add(DateTime.utc_now(), 7, :day),
          scraped_at: DateTime.utc_now()
        })

      assert length(Events.listed_events(store.id)) == 2
      assert [dated] = Events.upcoming_events(store.id)
      assert dated.title == "A dated reading"
    end

    test "dateless events sort last, after the soonest-first dated ones" do
      store = insert(:bookstore)

      for {title, date} <- [
            {"dateless", nil},
            {"in a month", DateTime.add(DateTime.utc_now(), 30, :day)},
            {"next week", DateTime.add(DateTime.utc_now(), 7, :day)}
          ] do
        {:ok, _} =
          Events.upsert_event(%{
            store_id: store.id,
            title: title,
            event_date: date,
            scraped_at: DateTime.utc_now()
          })
      end

      assert ["next week", "in a month", "dateless"] =
               store.id |> Events.listed_events() |> Enum.map(& &1.title)
    end
  end
end
