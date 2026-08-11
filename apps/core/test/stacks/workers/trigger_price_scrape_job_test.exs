defmodule Stacks.Workers.TriggerPriceScrapeJobTest do
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Enrichment.MockScraperClient
  alias Stacks.Workers.TriggerPriceScrapeJob

  setup do
    start_supervised!(Stacks.Enrichment.PricePipeline)
    :ok
  end

  describe "perform/1 with single ISBN" do
    test "scrapes a single ISBN across all stores" do
      _edition = insert(:book_edition, isbn: "9780743273565")
      store = insert(:bookstore)

      MockScraperClient.put_response("9780743273565", store.scraper_module, {
        :ok,
        %{
          "isbn" => "9780743273565",
          "store" => store.scraper_module,
          "price_cents" => 15_000,
          "currency" => "ZAR",
          "in_stock" => true,
          "url" => "https://example.com/book/9780743273565",
          "selector_match_rate" => 0.95,
          "outcome" => "SCRAPE_OUTCOME_PRICED"
        }
      })

      job = TriggerPriceScrapeJob.new(%{isbn: "9780743273565"})
      assert :ok = perform_job(TriggerPriceScrapeJob, job.changes.args)
    end

    test "returns ok when no stores configured" do
      _edition = insert(:book_edition, isbn: "9780743273565")
      job = TriggerPriceScrapeJob.new(%{isbn: "9780743273565"})
      assert :ok = perform_job(TriggerPriceScrapeJob, job.changes.args)
    end
  end

  describe "perform/1 edition resolution" do
    test "skips without scraping when the ISBN matches no edition" do
      store = insert(:bookstore)
      MockScraperClient.put_response("9789999999999", store.scraper_module, {:error, :timeout})

      job = TriggerPriceScrapeJob.new(%{isbn: "9789999999999"})

      assert :ok = perform_job(TriggerPriceScrapeJob, job.changes.args)
    end

    test "prefers an explicitly supplied book_edition_id over resolving the ISBN" do
      edition = insert(:book_edition, isbn: "9780743273565")
      store = insert(:bookstore)

      MockScraperClient.put_response("9780743273565", store.scraper_module, {
        :ok,
        %{
          "isbn" => "9780743273565",
          "store" => store.scraper_module,
          "price_cents" => 12_345,
          "currency" => "ZAR",
          "in_stock" => true,
          "url" => "https://example.com/book",
          "outcome" => "SCRAPE_OUTCOME_PRICED"
        }
      })

      job =
        TriggerPriceScrapeJob.new(%{
          isbn: "9780743273565",
          book_edition_id: edition.id
        })

      assert :ok = perform_job(TriggerPriceScrapeJob, job.changes.args)
    end
  end

  describe "scrape outcomes" do
    setup do
      edition = insert(:book_edition, isbn: "9780743273565")
      %{edition: edition, store: insert(:bookstore)}
    end

    defp respond(store, outcome, extra \\ %{}) do
      MockScraperClient.put_response(
        "9780743273565",
        store.scraper_module,
        {:ok,
         Map.merge(
           %{
             "isbn" => "9780743273565",
             "store" => store.scraper_module,
             "currency" => "ZAR",
             "outcome" => outcome
           },
           extra
         )}
      )
    end

    defp run_scrape do
      job = TriggerPriceScrapeJob.new(%{isbn: "9780743273565"})
      perform_job(TriggerPriceScrapeJob, job.changes.args)
    end

    test "a robots.txt block is not a failure", %{store: store} do
      respond(store, "SCRAPE_OUTCOME_ROBOTS_BLOCKED", %{
        "detail" => "robots.txt disallows https://example.com/search?q=9780743273565"
      })

      assert :ok = run_scrape()
    end

    test "a rate-limit is a determination, not a failure", %{store: store} do
      # The shop is pacing us — 429, or a cooldown it asked for. It recurs on
      # every attempt until the cooldown lapses, the identical trap
      # ROBOTS_BLOCKED was split out to avoid, so it must not count against
      # the shared fuse (scraper.proto SCRAPE_OUTCOME_RATE_LIMITED).
      respond(store, "SCRAPE_OUTCOME_RATE_LIMITED", %{
        "detail" => "shop answered 429 for https://example.com/search?q=9780743273565"
      })

      assert :ok = run_scrape()
    end

    test "a rate-limit records source-health success and does not retry", %{store: store} do
      respond(store, "SCRAPE_OUTCOME_RATE_LIMITED")

      refute match?({:error, _}, run_scrape())

      health =
        Core.Repo.get_by!(Stacks.Monitoring.SourceHealthCheck,
          source_name: store.scraper_module
        )

      assert health.status == "healthy"
      assert health.total_successes == 1
      assert health.total_failures in [0, nil]
    end

    test "not stocked is a real answer, not a failure", %{store: store} do
      respond(store, "SCRAPE_OUTCOME_NOT_STOCKED")

      assert :ok = run_scrape()
    end

    test "needing an index enqueues a build instead of failing", %{store: store} do
      # The index lives in the scraper service's process and dies with it, so a restart
      # would leave the four index-needing shops unpriceable until the nightly rebuild.
      # Reacting to the outcome makes cron a belt-and-braces refresh, not the only path.
      respond(store, "SCRAPE_OUTCOME_INDEX_REQUIRED", %{
        "detail" => "za/wordsworth needs a local ISBN index before 9780743273565"
      })

      assert :ok = run_scrape()

      assert_enqueued(
        worker: Stacks.Workers.BuildScraperIndexJob,
        args: %{store: store.scraper_module}
      )
    end

    test "repeated lookups against an unindexed store enqueue one build", %{store: store} do
      respond(store, "SCRAPE_OUTCOME_INDEX_REQUIRED")

      Enum.each(1..4, fn _ -> run_scrape() end)

      assert length(all_enqueued(worker: Stacks.Workers.BuildScraperIndexJob)) == 1
    end

    test "an extractor failure is a failure", %{store: store} do
      respond(store, "SCRAPE_OUTCOME_EXTRACTOR_FAILED", %{
        "detail" => "price selector matched nothing: .product-price"
      })

      assert {:error, "all scrape requests failed"} = run_scrape()
    end

    test "a response that cannot say what it concluded is treated as a failure",
         %{store: store} do
      MockScraperClient.put_response(
        "9780743273565",
        store.scraper_module,
        {:ok, %{"isbn" => "9780743273565", "store" => store.scraper_module, "currency" => "ZAR"}}
      )

      assert {:error, "all scrape requests failed"} = run_scrape()
    end
  end

  describe "perform/1 with batch mode" do
    test "returns ok when nothing to scrape" do
      job = TriggerPriceScrapeJob.new(%{batch: true})
      assert :ok = perform_job(TriggerPriceScrapeJob, job.changes.args)
    end
  end

  describe "perform/1 with unrecognized args" do
    test "returns ok for unknown args" do
      assert :ok = perform_job(TriggerPriceScrapeJob, %{"unknown" => true})
    end
  end

  describe "circuit breaker propagation" do
    test "returns error when ScraperClient reports circuit open" do
      _edition = insert(:book_edition, isbn: "9780743273565")
      store = insert(:bookstore)

      MockScraperClient.put_response(
        "9780743273565",
        store.scraper_module,
        {:error, :circuit_open}
      )

      job = TriggerPriceScrapeJob.new(%{isbn: "9780743273565"})

      assert {:error, "all scrape requests failed"} =
               perform_job(TriggerPriceScrapeJob, job.changes.args)
    end
  end

  describe "scraper failure" do
    test "melts fuse on scraper error and returns ok when not all fail" do
      _edition = insert(:book_edition, isbn: "9780743273565")
      store1 = insert(:bookstore)
      store2 = insert(:bookstore)

      MockScraperClient.put_response("9780743273565", store1.scraper_module, {:error, :timeout})

      MockScraperClient.put_response("9780743273565", store2.scraper_module, {
        :ok,
        %{
          "isbn" => "9780743273565",
          "store" => store2.scraper_module,
          "price_cents" => 20_000,
          "currency" => "ZAR",
          "in_stock" => true,
          "url" => "https://example.com/book",
          "selector_match_rate" => 0.9,
          "outcome" => "SCRAPE_OUTCOME_PRICED"
        }
      })

      job = TriggerPriceScrapeJob.new(%{isbn: "9780743273565"})
      assert :ok = perform_job(TriggerPriceScrapeJob, job.changes.args)
    end

    test "returns error when all scrape requests fail" do
      _edition = insert(:book_edition, isbn: "9780743273565")
      store = insert(:bookstore)

      MockScraperClient.put_response("9780743273565", store.scraper_module, {:error, :timeout})

      job = TriggerPriceScrapeJob.new(%{isbn: "9780743273565"})

      assert {:error, "all scrape requests failed"} =
               perform_job(TriggerPriceScrapeJob, job.changes.args)
    end
  end
end
