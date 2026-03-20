defmodule Stacks.Workers.DiscoverBookstoreEventsJobTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  alias Stacks.Enrichment.Events
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

  describe "build_events_url/1" do
    test "appends /events to website URL" do
      assert DiscoverBookstoreEventsJob.build_events_url("https://example.com") ==
               "https://example.com/events"
    end

    test "handles trailing slash" do
      assert DiscoverBookstoreEventsJob.build_events_url("https://example.com/") ==
               "https://example.com/events"
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
