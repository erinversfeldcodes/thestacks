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
      # batch mode should not crash even if no stores have URLs
      job = %Oban.Job{args: %{"batch" => true}}
      assert :ok = DiscoverBookstoreEventsJob.perform(job)
    end
  end

  # ---------------------------------------------------------------------------
  # Compliance — the egress (campaign C3) and the recorded block (C4)
  # ---------------------------------------------------------------------------

  describe "compliance: the events page is fetched through the compliant egress" do
    setup do
      on_exit(&MockScraperClient.clear/0)
      :ok
    end

    test "a store with no scraper config is never fetched" do
      # The guarantee is structural, not a policy check: the egress is keyed by scraper
      # config, which supplies the base URL and the rate limit. No config means no
      # declared crawl policy, so the store cannot be fetched at all.
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
      # Reporting a disallow as an error would melt the store's fuse on every run, for
      # a condition that recurs by definition — and the shared service fuse with it.
      store = insert(:bookstore, scraper_module: "za/test_store")

      MockScraperClient.put_page(
        "za/test_store",
        "/events",
        {:error, {:robots_blocked, "Disallow: /events"}}
      )

      # `{:ok, _}` rather than a bare `:ok`: the classification is what the batch summary tallies,
      # and the point of the assertion is that it is an :ok at all, not an :error.
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
      # Without this the store stays marked blocked forever and "re-checked on the probe
      # cadence" is a claim with nothing behind it.
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

      assert :ok =
               DiscoverBookstoreEventsJob.perform(%Oban.Job{args: %{"store_id" => store.id}})

      reloaded = Repo.get!(Bookstore, store.id)

      assert is_nil(reloaded.robots_blocked_path)
      assert is_nil(reloaded.robots_blocked_rule)

      assert is_nil(reloaded.robots_blocked_at),
             "all three move together — a half-cleared block reads as 'blocked, reason unknown'"
    end

    test "a 404 events page is data, not a failure" do
      # Plenty of shops have no /events page. Treating that as a failure would melt the
      # store's fuse for a condition that is simply true of the shop.
      store = insert(:bookstore, scraper_module: "za/test_store")
      MockScraperClient.put_page("za/test_store", "/events", {:ok, %{status: 404, body: ""}})

      # `{:ok, :no_events_page}` rather than a bare `:ok`: the batch summary counts these so a run that
      # writes zero events explains WHY per store. It took a direct fetch to establish that `/events`
      # 404s on both scrapeable stores — that belonged in the log, not in an investigation. Oban treats
      # `:ok` and `{:ok, term}` alike, so this is a reporting change, not a behavioural one.
      assert {:ok, :no_events_page} =
               DiscoverBookstoreEventsJob.perform(%Oban.Job{args: %{"store_id" => store.id}})

      assert is_nil(Repo.get!(Bookstore, store.id).robots_blocked_path),
             "a missing page is not a robots block"
    end
  end

  # Asserts directly on the egress rather than on a downstream side effect: "no events
  # were persisted" would also hold if the fetch happened and returned nothing
  # parseable, which is the wrong-selector failure mode wearing the right answer's face.
  defp refute_any_fetch_of(store) do
    fetched = Enum.map(MockScraperClient.fetches(), fn {s, _p} -> s end)

    refute store.scraper_module in fetched,
           "store #{store.name} was fetched despite having no scraper config"

    refute nil in fetched,
           "a fetch was attempted with a nil store key — the config gate did not hold"
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

  # `build_events_url/1` and its two tests were removed when the job moved onto the
  # scraper's compliant egress. It concatenated a caller-supplied host with "/events";
  # the egress now resolves a *relative* path against the store's configured base URL,
  # which is what stops a caller steering the rate-limited, robots-checked channel at
  # another host. The trailing-slash handling those tests covered lives in Rust's
  # `fetch_path` (`trim_end_matches('/')`) and is tested there, so no coverage was lost
  # — the behaviour moved rather than disappeared.

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
      # ⛔ It used to be `Enum.at(dates, idx)` — the nth heading paired with the nth ISO date found
      # anywhere in the document. Those lists have no relationship: headings include site chrome and
      # dates appear in footers, scripts and JSON-LD.
      #
      # Measured on a real Shopify page (Wordsworth, 2026-07-29): the headings a regex like this
      # matches are "Subscribe", "Follow us", "Disclaimer", "Reset your password". Pairing those with
      # arbitrary dates would have produced confident, wrong records — worse than none, because a
      # pipeline that invents data is harder to notice and harder to undo than one that produces none.
      store = insert(:bookstore)

      html = """
      <h2>Author Evening</h2>
      <p>2026-03-01</p>
      <h2>Poetry Night</h2>
      <p>2026-09-30</p>
      """

      events = DiscoverBookstoreEventsJob.parse_events(html, store)

      assert length(events) == 2

      assert Enum.all?(events, &is_nil(&1.event_date)),
             "a date was assigned by position, which pairs a title with an unrelated date"
    end

    test "one distinct date repeated beside every entry IS used" do
      # Unambiguous means one DISTINCT date, not one occurrence. A listing that repeats the same date
      # next to each entry is common and perfectly clear; refusing it would throw away good data.
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

      # Persist them via upsert to verify the full path
      Enum.each(events, fn event_attrs ->
        assert {:ok, _} = Events.upsert_event(event_attrs)
      end)

      upcoming = Events.upcoming_events(store.id)
      assert length(upcoming) == 2
    end

    test "upsert_event handles changeset errors gracefully" do
      # Missing required store_id should return an error changeset
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
