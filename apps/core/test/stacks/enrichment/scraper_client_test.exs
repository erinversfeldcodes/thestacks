defmodule Stacks.Enrichment.ScraperClientTest do
  @moduledoc """
  The `/fetch` outcome contract between this client and the Rust sidecar.

  ⚠️ **None of these branches had any coverage.** Tests swap the whole module out for
  `MockScraperClient` and there is no Finch stub in this project, so every decision about what a
  shop's answer *means* was unreachable from a test — including the one that decides whether an
  answer melts `:scraper_fuse`, which is shared by every store and opens for 15 minutes after three
  failures. `classify_fetch_body/2` was made public precisely so this file could exist.

  The invariant under test: **`{:unexpected, _}` is the only return that melts a fuse.** So proving
  an outcome is not `{:unexpected, _}` proves it cannot take price scraping down for other shops.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Stacks.Enrichment.ScraperClient

  defp classify(payload) do
    capture_log(fn ->
      send(
        self(),
        {:result, ScraperClient.classify_fetch_body(Jason.encode!(payload), "za/test")}
      )
    end)

    receive do
      {:result, result} -> result
    end
  end

  describe "classify_fetch_body/2 — determinations must not melt the shared fuse" do
    test "a rate-limited outcome is a determination carrying the cooldown" do
      assert {:error, {:rate_limited, 120}} =
               classify(%{
                 "outcome" => "FETCH_OUTCOME_RATE_LIMITED",
                 "status" => 0,
                 "body" => "",
                 "retry_after_seconds" => 120
               })
    end

    test "a rate-limited outcome without a cooldown still waits rather than defaulting to zero" do
      # The sidecar always sets it, but a field read with `Map.get/2` and no default would return
      # nil here and a caller doing arithmetic on it would crash — turning the shop's polite request
      # into an exception on our side.
      assert {:error, {:rate_limited, 60}} =
               classify(%{"outcome" => "FETCH_OUTCOME_RATE_LIMITED", "status" => 0, "body" => ""})
    end

    test "a robots block is a determination carrying the rule" do
      assert {:error, {:robots_blocked, "Disallow: /events"}} =
               classify(%{
                 "outcome" => "FETCH_OUTCOME_ROBOTS_BLOCKED",
                 "status" => 0,
                 "body" => "",
                 "robots_rule" => "Disallow: /events"
               })
    end

    test "neither determination is classified as unexpected, which is what melts the fuse" do
      # Stated as its own assertion because this — not the tuple shapes above — is the guarantee.
      # An outcome the sidecar sends and this client does not recognise melts `:scraper_fuse`, so
      # adding an outcome to the proto without adding a clause here makes it worse than silence.
      for outcome <- ["FETCH_OUTCOME_RATE_LIMITED", "FETCH_OUTCOME_ROBOTS_BLOCKED"] do
        refute match?(
                 {:unexpected, _},
                 classify(%{
                   "outcome" => outcome,
                   "status" => 0,
                   "body" => "",
                   "robots_rule" => "Disallow: /",
                   "retry_after_seconds" => 30
                 })
               ),
               "#{outcome} melts the fuse shared by every store"
      end
    end
  end

  describe "classify_fetch_body/2 — a successful fetch" do
    test "carries the sitemaps the shop declared" do
      assert {:ok, %{status: 200, body: "<html/>", sitemaps: ["https://x.test/sitemap.xml"]}} =
               classify(%{
                 "outcome" => "FETCH_OUTCOME_FETCHED",
                 "status" => 200,
                 "body" => "<html/>",
                 "sitemaps" => ["https://x.test/sitemap.xml"]
               })
    end

    test "an absent sitemaps key is an empty list, not a crash" do
      # The sidecar omits the key entirely when robots.txt declared nothing — `skip_serializing_if`
      # on the Rust struct — because an absent key means "nothing was declared" while `[]` would
      # read as a positive claim that the shop has no index.
      assert {:ok, %{sitemaps: []}} =
               classify(%{
                 "outcome" => "FETCH_OUTCOME_FETCHED",
                 "status" => 200,
                 "body" => "<html/>"
               })
    end

    test "an upstream 404 is passed through as data, not an error" do
      # Plenty of shops have no /events page. The fetch succeeded; the page does not exist.
      assert {:ok, %{status: 404}} =
               classify(%{
                 "outcome" => "FETCH_OUTCOME_FETCHED",
                 "status" => 404,
                 "body" => "not found"
               })
    end
  end

  describe "classify_fetch_body/2 — contract mismatches" do
    test "an outcome this client does not know is flagged for the caller to melt" do
      assert {:unexpected, _} = classify(%{"outcome" => "FETCH_OUTCOME_SOMETHING_NEW"})
    end

    test "an unset outcome is not read as success" do
      # proto3's zero value. Treating "unset" as FETCHED is the trap the FetchOutcome enum
      # documents itself as existing to avoid.
      assert {:unexpected, _} =
               classify(%{
                 "outcome" => "FETCH_OUTCOME_UNSPECIFIED",
                 "status" => 200,
                 "body" => "x"
               })
    end

    test "a body that is not JSON at all is a mismatch rather than a crash" do
      log =
        capture_log(fn ->
          send(
            self(),
            {:result, ScraperClient.classify_fetch_body("<html>502</html>", "za/test")}
          )
        end)

      assert_received {:result, {:unexpected, _}}
      _ = log
    end
  end
end
