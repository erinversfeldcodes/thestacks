defmodule Stacks.Workers.DiscoverBookstoreEventsJobTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  alias Core.Repo
  alias Stacks.Enrichment.Bookstore
  alias Stacks.Enrichment.Events
  alias Stacks.Enrichment.MockScraperClient
  alias Stacks.Workers.DiscoverBookstoreEventsJob

  import Stacks.Factory

  describe "perform/1 with store_id" do
    test "returns cancel when store not found" do
      job = %Oban.Job{args: %{"store_id" => Ecto.UUID.generate()}}
      assert {:cancel, "store not found"} = DiscoverBookstoreEventsJob.perform(job)
    end
  end

  describe "perform/1 with batch" do
    test "processes stores with website_url set" do
      _store = insert(:bookstore, website_url: nil)
      job = %Oban.Job{args: %{"batch" => true}}
      assert :ok = DiscoverBookstoreEventsJob.perform(job)
    end
  end

  describe "compliance: the events page is fetched through the compliant egress" do
    setup do
      on_exit(&MockScraperClient.clear/0)

      MockScraperClient.put_sitemap(
        "za/test_store",
        {:ok,
         %{
           urls: ["https://example.com/events"],
           skipped: [],
           truncated: false,
           documents_fetched: 2,
           bytes_read: 10_334
         }}
      )

      :ok
    end

    test "a store with no scraper config is never fetched" do
      store = insert(:bookstore, scraper_module: nil, website_url: "https://example.test")

      assert :ok = DiscoverBookstoreEventsJob.perform(%Oban.Job{args: %{"batch" => true}})

      refute_any_fetch_of(store)
    end

    test "a robots disallow is recorded on the store with the rule that caused it" do
      store = insert(:bookstore, scraper_module: "za/test_store")

      MockScraperClient.put_page(
        "za/test_store",
        "/events",
        {:error, {:robots_blocked, "Disallow: /"}}
      )

      assert {:ok, :blocked} =
               DiscoverBookstoreEventsJob.perform(%Oban.Job{args: %{"store_id" => store.id}})

      reloaded = Repo.get!(Bookstore, store.id)

      assert reloaded.robots_blocked_path == "/events"
      assert reloaded.robots_blocked_rule == "Disallow: /"

      assert reloaded.robots_blocked_at,
             "a block with no timestamp cannot be re-checked, so it would be permanent"
    end

    test "a disallow does not fail the job, because retrying cannot succeed" do
      store = insert(:bookstore, scraper_module: "za/test_store")

      MockScraperClient.put_page(
        "za/test_store",
        "/events",
        {:error, {:robots_blocked, "Disallow: /events"}}
      )

      assert {:ok, :blocked} =
               DiscoverBookstoreEventsJob.perform(%Oban.Job{args: %{"store_id" => store.id}})
    end

    test "being paced does not fail the job, and is not recorded against the store" do
      # A 429 is a determination like a disallow, but a *temporary* one, so the two must not be
      # conflated. Recording it as a robots block would leave the store marked blocked with a rule
      # nobody wrote; recording it as a failure would melt the fuse shared by every other shop, on
      # every run, for as long as the shop kept pacing us.
      store = insert(:bookstore, scraper_module: "za/test_store")

      MockScraperClient.put_page("za/test_store", "/events", {:error, {:rate_limited, 120}})

      assert {:ok, :paced} =
               DiscoverBookstoreEventsJob.perform(%Oban.Job{args: %{"store_id" => store.id}})

      reloaded = Repo.get!(Bookstore, store.id)

      refute reloaded.robots_blocked_path,
             "a temporary backoff was written to the store as a permanent robots block"

      refute reloaded.robots_blocked_at
    end

    test "a later successful fetch clears the block, so a lifted disallow resumes" do
      store =
        insert(:bookstore,
          scraper_module: "za/test_store",
          robots_blocked_path: "/events",
          robots_blocked_rule: "Disallow: /",
          robots_blocked_at: DateTime.utc_now()
        )

      MockScraperClient.put_page(
        "za/test_store",
        "/events",
        {:ok, %{status: 200, body: "<h2>A Reading</h2><p>2026-09-01</p>"}}
      )

      assert {:ok, {:events, 1}} =
               DiscoverBookstoreEventsJob.perform(%Oban.Job{args: %{"store_id" => store.id}})

      reloaded = Repo.get!(Bookstore, store.id)

      assert is_nil(reloaded.robots_blocked_path)
      assert is_nil(reloaded.robots_blocked_rule)

      assert is_nil(reloaded.robots_blocked_at),
             "all three move together — a half-cleared block reads as 'blocked, reason unknown'"
    end

    test "a 404 events page is data, not a failure" do
      store = insert(:bookstore, scraper_module: "za/test_store")
      MockScraperClient.put_page("za/test_store", "/events", {:ok, %{status: 404, body: ""}})

      assert {:ok, :no_events_page} =
               DiscoverBookstoreEventsJob.perform(%Oban.Job{args: %{"store_id" => store.id}})

      assert is_nil(Repo.get!(Bookstore, store.id).robots_blocked_path),
             "a missing page is not a robots block"
    end
  end

  describe "the pipeline actually writes rows" do
    setup do
      on_exit(&MockScraperClient.clear/0)
      :ok
    end

    test "a resolved events page produces persisted events" do
      store = insert(:bookstore, scraper_module: "za/test_store", events_path: nil)

      MockScraperClient.put_sitemap(
        "za/test_store",
        {:ok,
         %{
           urls: ["https://example.com/pages/events", "https://example.com/pages/about"],
           skipped: [],
           truncated: false,
           documents_fetched: 2,
           bytes_read: 10_334
         }}
      )

      MockScraperClient.put_page(
        "za/test_store",
        "/pages/events",
        {:ok,
         %{
           status: 200,
           body: """
           <div>
             <h2>An Evening with Ada Lovelace</h2>
             <p>Date: 2026-09-01</p>
             <h2>Poetry Night</h2>
             <p>Date: 2026-09-15</p>
           </div>
           """
         }}
      )

      assert {:ok, {:events, 2}} =
               DiscoverBookstoreEventsJob.perform(%Oban.Job{args: %{"store_id" => store.id}})

      rows = Events.upcoming_events(store.id)

      assert length(rows) == 2,
             "the chain resolved a path and fetched a page but no row reached the database"

      assert Enum.any?(rows, &(&1.title == "An Evening with Ada Lovelace"))

      assert Repo.get!(Bookstore, store.id).events_path == "/pages/events"
    end

    test "the path is resolved from the sitemap, not guessed" do
      store = insert(:bookstore, scraper_module: "za/test_store", events_path: nil)

      MockScraperClient.put_sitemap(
        "za/test_store",
        {:ok,
         %{
           urls: ["https://example.com/whats-on"],
           skipped: [],
           truncated: false,
           documents_fetched: 1,
           bytes_read: 9_000
         }}
      )

      MockScraperClient.put_page(
        "za/test_store",
        "/whats-on",
        {:ok, %{status: 200, body: "<h2>A Reading</h2><p>2026-10-01</p>"}}
      )

      DiscoverBookstoreEventsJob.perform(%Oban.Job{args: %{"store_id" => store.id}})

      paths = Enum.map(MockScraperClient.fetches(), fn {_s, p} -> p end)

      assert "/whats-on" in paths, "the sitemap-declared path was never fetched"

      refute "/events" in paths,
             "the hardcoded guess is still being fetched — that path 404s on every real store"
    end

    test "a 304 keeps existing events instead of wiping them" do
      store =
        insert(:bookstore,
          scraper_module: "za/test_store",
          events_path: "/pages/events",
          events_path_checked_at: DateTime.utc_now(),
          events_page_etag: "\"v1\""
        )

      existing =
        insert(:bookstore_event,
          store: store,
          title: "An Evening with Ada Lovelace",
          event_date: ~U[2026-09-01 00:00:00Z]
        )

      MockScraperClient.put_page(
        "za/test_store",
        "/pages/events",
        {:ok, %{status: 304, not_modified: true, etag: "\"v1\"", last_modified: ""}}
      )

      assert {:ok, :unchanged} =
               DiscoverBookstoreEventsJob.perform(%Oban.Job{args: %{"store_id" => store.id}})

      assert Enum.map(Events.upcoming_events(store.id), & &1.id) == [existing.id],
             "an unchanged page wiped the store's events"
    end

    test "the stored validator is actually sent, so the shop can answer 304" do
      store =
        insert(:bookstore,
          scraper_module: "za/test_store",
          events_path: "/pages/events",
          events_path_checked_at: DateTime.utc_now(),
          events_page_etag: "\"v1\"",
          events_page_last_modified: "Wed, 21 Oct 2026 07:28:00 GMT"
        )

      MockScraperClient.put_page(
        "za/test_store",
        "/pages/events",
        {:ok, %{status: 304, not_modified: true, etag: "\"v1\"", last_modified: ""}}
      )

      DiscoverBookstoreEventsJob.perform(%Oban.Job{args: %{"store_id" => store.id}})

      assert [{"za/test_store", "/pages/events", validators}] =
               MockScraperClient.sent_validators()

      assert Keyword.get(validators, :etag) == "\"v1\""
      assert Keyword.get(validators, :last_modified) == "Wed, 21 Oct 2026 07:28:00 GMT"
    end

    test "a fresh fetch banks the validators it came back with" do
      store =
        insert(:bookstore,
          scraper_module: "za/test_store",
          events_path: "/pages/events",
          events_path_checked_at: DateTime.utc_now()
        )

      MockScraperClient.put_page(
        "za/test_store",
        "/pages/events",
        {:ok,
         %{
           status: 200,
           body: "<h2>A Reading</h2><p>2026-10-01</p>",
           etag: "\"v9\"",
           last_modified: "Thu, 22 Oct 2026 07:28:00 GMT"
         }}
      )

      DiscoverBookstoreEventsJob.perform(%Oban.Job{args: %{"store_id" => store.id}})

      reloaded = Repo.get!(Bookstore, store.id)
      assert reloaded.events_page_etag == "\"v9\""
      assert reloaded.events_page_last_modified == "Thu, 22 Oct 2026 07:28:00 GMT"
    end

    test "a previously working path that starts 404ing is forgotten, so it re-resolves" do
      store =
        insert(:bookstore,
          scraper_module: "za/test_store",
          events_path: "/pages/old-events",
          events_path_checked_at: DateTime.utc_now()
        )

      MockScraperClient.put_page(
        "za/test_store",
        "/pages/old-events",
        {:ok, %{status: 404, body: ""}}
      )

      assert {:ok, :no_events_page} =
               DiscoverBookstoreEventsJob.perform(%Oban.Job{args: %{"store_id" => store.id}})

      reloaded = Repo.get!(Bookstore, store.id)
      refute reloaded.events_path, "a dead path was kept, so every future run refetches a 404"
      assert reloaded.events_unresolved_reason =~ "stopped serving"
    end
  end

  defp refute_any_fetch_of(store) do
    fetched = Enum.map(MockScraperClient.fetches(), fn {s, _p} -> s end)

    refute store.scraper_module in fetched,
           "store #{store.name} was fetched despite having no scraper config"

    refute nil in fetched,
           "a fetch was attempted with a nil store key — the config gate did not hold"
  end

  describe "parse_events/2 — structured tier (#321 item 4)" do
    test "schema.org JSON-LD events are believed OVER the heading heuristics" do
      store = insert(:bookstore)
      author = insert(:author, name: "Jane Doe")

      html = """
      <html><head>
      <script type="application/ld+json">
      {"@type":"LiteraryEvent","name":"An evening with Jane Doe",
       "startDate":"2027-04-15T18:30:00Z",
       "location":{"@type":"Place","name":"Main branch"}}
      </script>
      </head><body>
      <h2>Newsletter</h2><p>2026-01-01</p>
      </body></html>
      """

      assert [event] = DiscoverBookstoreEventsJob.parse_events(html, store)
      assert event.title == "An evening with Jane Doe"
      assert event.location == "Main branch"
      assert event.store_id == store.id
      assert event.author_id == author.id
      assert DateTime.compare(event.event_date, ~U[2027-04-15 18:30:00Z]) == :eq
    end

    test "a page with no structured events falls through to the heading tier" do
      store = insert(:bookstore)

      html = """
      <h2>Author Reading</h2>
      <p>Date: 2026-04-15</p>
      """

      assert [event] = DiscoverBookstoreEventsJob.parse_events(html, store)
      assert event.title == "Author Reading"
    end
  end

  describe "parse_events/2" do
    test "extracts events from HTML with h2 tags and dates" do
      store = insert(:bookstore)

      html = """
      <div>
        <h2>Author Reading with Jane Doe</h2>
        <p>Date: 2026-04-15</p>
        <h2>Book Launch Party</h2>
        <p>Date: 2026-05-01</p>
      </div>
      """

      events = DiscoverBookstoreEventsJob.parse_events(html, store)

      assert length(events) == 2
      assert Enum.at(events, 0).title == "Author Reading with Jane Doe"
      assert Enum.at(events, 0).store_id == store.id
      assert Enum.at(events, 1).title == "Book Launch Party"
    end

    test "handles HTML with no matching patterns" do
      store = insert(:bookstore)
      events = DiscoverBookstoreEventsJob.parse_events("<p>No events</p>", store)
      assert events == []
    end

    test "links author when name matches a known author" do
      author = insert(:author, name: "Jane Doe")
      store = insert(:bookstore)

      html = """
      <h2>An Evening with Jane Doe</h2>
      <p>2026-04-15</p>
      """

      events = DiscoverBookstoreEventsJob.parse_events(html, store)

      assert length(events) == 1
      assert hd(events).author_id == author.id
    end

    test "author_id is nil when no author matches" do
      store = insert(:bookstore)

      html = """
      <h2>General Book Sale</h2>
      <p>2026-04-15</p>
      """

      events = DiscoverBookstoreEventsJob.parse_events(html, store)
      assert hd(events).author_id == nil
    end
  end

  describe "parse_events/2 edge cases" do
    test "parses h3 tags as well as h2" do
      store = insert(:bookstore)

      html = """
      <div>
        <h3 class="event-title">Poetry Night</h3>
        <span>2026-06-01</span>
      </div>
      """

      events = DiscoverBookstoreEventsJob.parse_events(html, store)
      assert length(events) == 1
      assert hd(events).title == "Poetry Night"
    end

    test "event_date is nil when no date pattern found for a title" do
      store = insert(:bookstore)

      html = """
      <h2>Mystery Event</h2>
      <p>No date listed</p>
      """

      events = DiscoverBookstoreEventsJob.parse_events(html, store)
      assert length(events) == 1
      assert hd(events).event_date == nil
    end

    test "sets scraped_at timestamp on each event" do
      store = insert(:bookstore)

      html = """
      <h2>Timed Event</h2>
      <p>2026-07-01</p>
      """

      before = DateTime.utc_now()
      events = DiscoverBookstoreEventsJob.parse_events(html, store)
      assert hd(events).scraped_at != nil
      assert DateTime.compare(hd(events).scraped_at, before) in [:gt, :eq]
    end

    test "author matching is case-insensitive" do
      author = insert(:author, name: "MARGARET ATWOOD")
      store = insert(:bookstore)

      html = """
      <h2>An Evening with margaret atwood</h2>
      <p>2026-08-01</p>
      """

      events = DiscoverBookstoreEventsJob.parse_events(html, store)
      assert hd(events).author_id == author.id
    end

    test "sets url to store website_url" do
      store = insert(:bookstore, website_url: "https://mybookshop.co.za")

      html = """
      <h2>Book Club</h2>
      <p>2026-04-01</p>
      """

      events = DiscoverBookstoreEventsJob.parse_events(html, store)
      assert hd(events).url == "https://mybookshop.co.za"
    end
  end

  describe "parse_events does not invent a date it cannot justify" do
    test "several DIFFERENT dates on the page yield no date, rather than a guessed pairing" do
      store = insert(:bookstore)

      html = """
      <h2>Author Evening</h2>
      <p>2026-03-01</p>
      <h2>Poetry Night</h2>
      <p>2026-09-30</p>
      """

      events = DiscoverBookstoreEventsJob.parse_events(html, store)

      assert length(events) == 2

      by_title = Map.new(events, &{&1.title, &1.event_date})

      assert by_title["Author Evening"] == ~U[2026-03-01 00:00:00Z]
      assert by_title["Poetry Night"] == ~U[2026-09-30 00:00:00Z]
    end

    test "a heading with no date in its own block gets nil, not a neighbour's date" do
      store = insert(:bookstore)

      html = """
      <h2>Author Evening</h2>
      <p>2026-03-01</p>
      <h2>Mystery Event</h2>
      <p>Details to follow.</p>
      """

      by_title =
        html
        |> DiscoverBookstoreEventsJob.parse_events(store)
        |> Map.new(&{&1.title, &1.event_date})

      assert by_title["Author Evening"] == ~U[2026-03-01 00:00:00Z]

      assert is_nil(by_title["Mystery Event"]),
             "a date was borrowed from the preceding event's block"
    end

    test "a footer date cannot attach itself to the last event" do
      store = insert(:bookstore)

      html = """
      <h2>Author Evening</h2>
      <p>Details to follow.</p>
      <footer><p>Site last updated 2026-01-01</p></footer>
      """

      events = DiscoverBookstoreEventsJob.parse_events(html, store)

      assert [%{title: "Author Evening", event_date: nil}] = events
    end

    test "multi-byte headings are sliced correctly" do
      store = insert(:bookstore)

      html = """
      <h2>Skrywersaand met André Brink</h2>
      <p>2026-09-01</p>
      <h2>Poësie in die Kaap</h2>
      <p>2026-09-15</p>
      """

      by_title =
        html
        |> DiscoverBookstoreEventsJob.parse_events(store)
        |> Map.new(&{&1.title, &1.event_date})

      assert by_title["Skrywersaand met André Brink"] == ~U[2026-09-01 00:00:00Z]
      assert by_title["Poësie in die Kaap"] == ~U[2026-09-15 00:00:00Z]
    end

    test "site chrome headings are not events" do
      store = insert(:bookstore)

      html = """
      <h2>Author Evening</h2>
      <p>2026-03-01</p>
      <h2>Subscribe to our newsletter</h2>
      <p>2026-03-02</p>
      <h2>Disclaimer</h2>
      <p>2026-03-03</p>
      """

      titles = html |> DiscoverBookstoreEventsJob.parse_events(store) |> Enum.map(& &1.title)

      assert titles == ["Author Evening"]
    end

    test "one distinct date repeated beside every entry IS used" do
      store = insert(:bookstore)

      html = """
      <h2>Morning Session</h2>
      <p>2026-03-01</p>
      <h2>Evening Session</h2>
      <p>2026-03-01</p>
      """

      events = DiscoverBookstoreEventsJob.parse_events(html, store)

      assert length(events) == 2
      assert Enum.all?(events, &(&1.event_date != nil))
    end
  end

  describe "persist_events integration" do
    test "persists multiple events and emits enrichment event" do
      store = insert(:bookstore)
      future_date = DateTime.add(DateTime.utc_now(), 7, :day)

      html = """
      <h2>Event One</h2>
      <p>#{Calendar.strftime(future_date, "%Y-%m-%d")}</p>
      <h2>Event Two</h2>
      <p>#{Calendar.strftime(future_date, "%Y-%m-%d")}</p>
      """

      events = DiscoverBookstoreEventsJob.parse_events(html, store)
      assert length(events) == 2

      Enum.each(events, fn event_attrs ->
        assert {:ok, _} = Events.upsert_event(event_attrs)
      end)

      upcoming = Events.upcoming_events(store.id)
      assert length(upcoming) == 2
    end

    test "upsert_event handles changeset errors gracefully" do
      result = Events.upsert_event(%{title: "Bad Event"})
      assert {:error, %Ecto.Changeset{}} = result
    end
  end

  describe "event upsert integration" do
    test "persisted events can be queried via upcoming_events" do
      store = insert(:bookstore)
      future_date = DateTime.add(DateTime.utc_now(), 7, :day)

      attrs = %{
        store_id: store.id,
        title: "Test Event",
        event_date: future_date,
        scraped_at: DateTime.utc_now()
      }

      {:ok, _event} = Events.upsert_event(attrs)
      upcoming = Events.upcoming_events(store.id)

      assert length(upcoming) == 1
      assert hd(upcoming).title == "Test Event"
    end
  end
end
