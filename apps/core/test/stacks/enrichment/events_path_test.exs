defmodule Stacks.Enrichment.EventsPathTest do
  @moduledoc """
  ⚠️ The assertions that matter here are the ones separating **"this shop has no events page"** from
  **"we were unable to look"**. Both produce no path, and conflating them writes a shop off with a
  verdict that never re-checks — the false negative the whole module is shaped around.
  """
  use Core.DataCase, async: true

  alias Core.Repo
  alias Stacks.Enrichment.Bookstore
  alias Stacks.Enrichment.EventsPath
  alias Stacks.Enrichment.MockScraperClient

  import Stacks.Factory

  setup do
    on_exit(&MockScraperClient.clear/0)
    :ok
  end

  defp store, do: insert(:bookstore, scraper_module: "za/test_store", events_path: nil)
  defp reload(s), do: Repo.get!(Bookstore, s.id)

  defp harvest(urls, opts \\ []) do
    {:ok,
     %{
       urls: urls,
       skipped: [],
       truncated: Keyword.get(opts, :truncated, false),
       documents_fetched: 2,
       bytes_read: 10_334
     }}
  end

  describe "best_candidate/1 — the judgement, tested without a network" do
    test "prefers an events page over a calendar" do
      # Token ORDER is the scoring. A shop with both usually has events as the listing and calendar as
      # something else (opening hours, a term diary), so the order is not cosmetic.
      assert EventsPath.best_candidate([
               "https://shop.test/pages/calendar",
               "https://shop.test/pages/events"
             ]) == "https://shop.test/pages/events"
    end

    test "prefers the shallower path, so a listing beats a page inside it" do
      assert EventsPath.best_candidate([
               "https://shop.test/pages/events/2024-archive",
               "https://shop.test/pages/events"
             ]) == "https://shop.test/pages/events"
    end

    test "recognises every declared token" do
      # Enumerated from the module's own list rather than restated here: a duplicated list drifts, and
      # a drifting list of tokens fails silently — the page simply stops being found.
      for token <- EventsPath.candidate_tokens() do
        url = "https://shop.test/pages/#{token}"

        assert EventsPath.best_candidate([url]) == url,
               "declared token #{token} is not actually matched"
      end
    end

    test "is case-insensitive" do
      assert EventsPath.best_candidate(["https://shop.test/Pages/EVENTS"]) ==
               "https://shop.test/Pages/EVENTS"
    end

    test "returns nil rather than a wrong guess when nothing matches" do
      assert EventsPath.best_candidate([
               "https://shop.test/pages/about",
               "https://shop.test/pages/shipping"
             ]) == nil
    end

    test "an empty list is nil, not a crash" do
      assert EventsPath.best_candidate([]) == nil
    end
  end

  describe "path_of/1" do
    test "keeps only the path, because a full URL could steer the egress elsewhere" do
      assert EventsPath.path_of("https://shop.test/pages/events") == "/pages/events"
      assert EventsPath.path_of("http://shop.test/events?year=2026") == "/events?year=2026"
      assert EventsPath.path_of("https://shop.test") == "/"
      assert EventsPath.path_of("https://shop.test/") == "/"
    end
  end

  describe "resolve/1 — a resolved path" do
    test "verifies the candidate and persists it" do
      s = store()
      MockScraperClient.put_sitemap("za/test_store", harvest(["https://shop.test/pages/events"]))

      MockScraperClient.put_page(
        "za/test_store",
        "/pages/events",
        {:ok, %{status: 200, body: ""}}
      )

      assert {:ok, "/pages/events"} = EventsPath.resolve(s)

      reloaded = reload(s)
      assert reloaded.events_path == "/pages/events"
      assert reloaded.events_path_checked_at
      refute reloaded.events_unresolved_reason
    end

    test "a known path short-circuits without touching the network" do
      # The cost this module exists to remove. Re-verifying on every run would put us back to one
      # request per store per run, which is what made the hardcoded path expensive in the first place.
      s = insert(:bookstore, scraper_module: "za/test_store", events_path: "/pages/events")

      assert {:ok, "/pages/events"} = EventsPath.resolve(s)

      assert MockScraperClient.sitemap_calls() == [],
             "a store with a known events path was walked again"

      assert MockScraperClient.fetches() == []
    end
  end

  describe "resolve/1 — a RESOLVED negative: the shop genuinely lists no events page" do
    test "records a reason and a checked_at, so the verdict is re-checkable" do
      s = store()

      MockScraperClient.put_sitemap(
        "za/test_store",
        harvest(["https://shop.test/pages/about", "https://shop.test/pages/shipping"])
      )

      assert {:error, :no_candidate} = EventsPath.resolve(s)

      reloaded = reload(s)
      refute reloaded.events_path

      assert reloaded.events_unresolved_reason =~ "no candidate matched",
             "a negative with no reason is not actionable"

      assert reloaded.events_path_checked_at,
             "without a checked_at this is indistinguishable from never having looked, so it can " <>
               "never be revisited"
    end

    test "does not fetch anything to confirm an absence" do
      # There is nothing to verify. A confirming fetch here would cost the shop a request to learn
      # something its own sitemap already told us.
      s = store()
      MockScraperClient.put_sitemap("za/test_store", harvest(["https://shop.test/pages/about"]))

      assert {:error, :no_candidate} = EventsPath.resolve(s)
      assert MockScraperClient.fetches() == []
    end
  end

  describe "resolve/1 — NOT a fact about the shop: we were unable to look" do
    test "no declared sitemap is recorded as could-not-look, not as absence" do
      # ⛔ The load-bearing distinction. `{:error, :no_sitemap_declared}` means the shop never showed us
      # its page list. Banking that as "no events page" writes the shop off on the strength of never
      # having asked.
      s = store()
      MockScraperClient.put_sitemap("za/test_store", {:error, :no_sitemap_declared})

      assert {:error, :no_sitemap_declared} = EventsPath.resolve(s)

      reason = reload(s).events_unresolved_reason
      assert reason =~ "could not look"

      refute reason =~ "no candidate",
             "an inability to look was recorded as the shop listing no events page"
    end

    test "a truncated walk with no candidate is could-not-look, not absence" do
      # The events page may well have been in the part of the sitemap the budget stopped us reading.
      s = store()

      MockScraperClient.put_sitemap(
        "za/test_store",
        harvest(["https://shop.test/pages/about"], truncated: true)
      )

      assert {:error, :no_candidate} = EventsPath.resolve(s)

      reason = reload(s).events_unresolved_reason
      assert reason =~ "truncated", "an incomplete walk was recorded as a complete answer"
      assert reason =~ "retry later"
    end

    test "being paced is could-not-look, and is never a robots block" do
      s = store()
      MockScraperClient.put_sitemap("za/test_store", {:error, {:rate_limited, 120}})

      assert {:error, {:rate_limited, 120}} = EventsPath.resolve(s)

      reloaded = reload(s)
      assert reloaded.events_unresolved_reason =~ "back off"

      refute reloaded.robots_blocked_path,
             "a temporary backoff was written to the store as a permanent robots block"
    end

    test "a candidate the shop lists but does not serve is unresolved, not an absence" do
      # The shop's sitemap is wrong. That says nothing about whether it holds events, so this must
      # stay re-checkable rather than becoming a verdict.
      s = store()
      MockScraperClient.put_sitemap("za/test_store", harvest(["https://shop.test/pages/events"]))

      MockScraperClient.put_page(
        "za/test_store",
        "/pages/events",
        {:ok, %{status: 404, body: ""}}
      )

      assert {:error, :unverified} = EventsPath.resolve(s)

      reloaded = reload(s)
      refute reloaded.events_path
      assert reloaded.events_unresolved_reason =~ "HTTP 404"
      assert reloaded.events_path_checked_at
    end
  end

  describe "resolve/1 — every outcome is stamped" do
    test "checked_at is written on success and on every failure alike" do
      # Stated as its own test because it is the invariant that makes all of the above legible: a
      # reason written without a timestamp leaves exactly the ambiguity the reason exists to remove.
      cases = [
        {harvest(["https://shop.test/pages/events"]), {:ok, %{status: 200, body: ""}}},
        {harvest(["https://shop.test/pages/about"]), nil},
        {{:error, :no_sitemap_declared}, nil},
        {{:error, {:rate_limited, 60}}, nil},
        {{:error, {:robots_blocked, "Disallow: /"}}, nil}
      ]

      for {sitemap, page} <- cases do
        MockScraperClient.clear()
        s = store()
        MockScraperClient.put_sitemap("za/test_store", sitemap)
        if page, do: MockScraperClient.put_page("za/test_store", "/pages/events", page)

        EventsPath.resolve(s)

        assert reload(s).events_path_checked_at,
               "no checked_at stamped for sitemap outcome #{inspect(sitemap)}"
      end
    end
  end
end
