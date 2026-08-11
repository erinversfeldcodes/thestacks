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

  describe "classify_fetch_body/2 — a 304 is unchanged, not empty" do
    test "a not-modified outcome never presents as a fetched empty page" do
      assert {:ok, result} =
               classify(%{
                 "outcome" => "FETCH_OUTCOME_NOT_MODIFIED",
                 "status" => 0,
                 "body" => "",
                 "etag" => "W/\"abc\""
               })

      assert result.not_modified == true
      assert result.status == 304

      refute Map.has_key?(result, :body),
             "a 304 carried a body key — a caller matching on `%{body: body}` would treat an " <>
               "unchanged page as an empty one and delete every event it holds"
    end

    test "the validators come back so the next request can be conditional too" do
      assert {:ok, %{etag: "W/\"v2\"", last_modified: "Wed, 21 Oct 2026 07:28:00 GMT"}} =
               classify(%{
                 "outcome" => "FETCH_OUTCOME_NOT_MODIFIED",
                 "etag" => "W/\"v2\"",
                 "last_modified" => "Wed, 21 Oct 2026 07:28:00 GMT"
               })
    end

    test "a not-modified outcome is not a fuse-melting mismatch" do
      refute match?({:unexpected, _}, classify(%{"outcome" => "FETCH_OUTCOME_NOT_MODIFIED"}))
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
      assert {:ok, %{sitemaps: []}} =
               classify(%{
                 "outcome" => "FETCH_OUTCOME_FETCHED",
                 "status" => 200,
                 "body" => "<html/>"
               })
    end

    test "carries the validators so the next fetch can be conditional" do
      assert {:ok, %{etag: "\"v9\"", last_modified: "Thu, 22 Oct 2026 07:28:00 GMT"}} =
               classify(%{
                 "outcome" => "FETCH_OUTCOME_FETCHED",
                 "status" => 200,
                 "body" => "<html/>",
                 "etag" => "\"v9\"",
                 "last_modified" => "Thu, 22 Oct 2026 07:28:00 GMT"
               })
    end

    test "an upstream 404 is passed through as data, not an error" do
      assert {:ok, %{status: 404}} =
               classify(%{
                 "outcome" => "FETCH_OUTCOME_FETCHED",
                 "status" => 404,
                 "body" => "not found"
               })
    end
  end

  describe "classify_sitemap_body/2" do
    defp classify_sitemap(payload) do
      capture_log(fn ->
        send(
          self(),
          {:result, ScraperClient.classify_sitemap_body(Jason.encode!(payload), "za/test")}
        )
      end)

      receive do
        {:result, result} -> result
      end
    end

    test "a harvest carries the urls, the cost, and what was deliberately skipped" do
      assert {:ok, harvest} =
               classify_sitemap(%{
                 "outcome" => "SITEMAP_OUTCOME_HARVESTED",
                 "urls" => ["https://shop.test/pages/events"],
                 "documents_fetched" => 2,
                 "bytes_read" => 12_500,
                 "skipped" => ["https://shop.test/sitemap_products_1.xml (catalogue-sized)"]
               })

      assert harvest.urls == ["https://shop.test/pages/events"]
      assert harvest.documents_fetched == 2
      assert harvest.bytes_read == 12_500
      assert length(harvest.skipped) == 1
      refute harvest.truncated
    end

    test "no declared sitemap is its own error, not an empty harvest" do
      assert {:error, :no_sitemap_declared} =
               classify_sitemap(%{"outcome" => "SITEMAP_OUTCOME_NO_SITEMAP_DECLARED"})
    end

    test "an empty harvest is still a harvest, and is not confused with the above" do
      assert {:ok, %{urls: []}} =
               classify_sitemap(%{
                 "outcome" => "SITEMAP_OUTCOME_HARVESTED",
                 "documents_fetched" => 1
               })
    end

    test "absent repeated fields default rather than crashing" do
      assert {:ok, %{urls: [], skipped: [], truncated: false, bytes_read: 0}} =
               classify_sitemap(%{"outcome" => "SITEMAP_OUTCOME_HARVESTED"})
    end

    test "a truncated walk is reported as such" do
      assert {:ok, %{truncated: true}} =
               classify_sitemap(%{
                 "outcome" => "SITEMAP_OUTCOME_HARVESTED",
                 "urls" => ["https://shop.test/pages/a"],
                 "truncated" => true
               })
    end

    test "being paced and being blocked are determinations, not fuse-melting mismatches" do
      assert {:error, {:rate_limited, 90}} =
               classify_sitemap(%{
                 "outcome" => "SITEMAP_OUTCOME_RATE_LIMITED",
                 "retry_after_seconds" => 90
               })

      assert {:error, {:robots_blocked, "Disallow: /sitemap.xml"}} =
               classify_sitemap(%{
                 "outcome" => "SITEMAP_OUTCOME_ROBOTS_BLOCKED",
                 "skipped" => ["Disallow: /sitemap.xml"]
               })

      for outcome <- [
            "SITEMAP_OUTCOME_RATE_LIMITED",
            "SITEMAP_OUTCOME_ROBOTS_BLOCKED",
            "SITEMAP_OUTCOME_NO_SITEMAP_DECLARED"
          ] do
        refute match?({:unexpected, _}, classify_sitemap(%{"outcome" => outcome})),
               "#{outcome} melts the fuse shared by every store"
      end
    end

    test "an unset outcome is not read as a harvest" do
      assert {:unexpected, _} = classify_sitemap(%{"outcome" => "SITEMAP_OUTCOME_UNSPECIFIED"})
    end
  end

  describe "classify_fetch_body/2 — contract mismatches" do
    test "an outcome this client does not know is flagged for the caller to melt" do
      assert {:unexpected, _} = classify(%{"outcome" => "FETCH_OUTCOME_SOMETHING_NEW"})
    end

    test "an unset outcome is not read as success" do
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
