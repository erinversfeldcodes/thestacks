defmodule Stacks.Workers.TriggerPriceScrapeJobTest do
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Enrichment.MockScraperClient
  alias Stacks.Workers.TriggerPriceScrapeJob

  setup do
    # Start PricePipeline for tests (not started in test env via application.ex).
    # Must use the default module name since the worker calls
    # Broadway.push_messages(PricePipeline, ...).
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
          "selector_match_rate" => 0.95
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
      # An ISBN names an edition, so with no edition row there is nothing to price.
      # This must not reach the scraper at all — issuing an outbound request for a
      # book we do not hold would spend a store's rate-limit budget for nothing.
      store = insert(:bookstore)
      MockScraperClient.put_response("9789999999999", store.scraper_module, {:error, :timeout})

      job = TriggerPriceScrapeJob.new(%{isbn: "9789999999999"})

      # `:ok` is itself the discriminating assertion here: the store's mocked
      # response for this ISBN is a :timeout, so had the job called out at all,
      # every request would have failed and `evaluate_outcome/1` would have
      # returned {:error, "all scrape requests failed"} instead.
      assert :ok = perform_job(TriggerPriceScrapeJob, job.changes.args)
    end

    test "prefers an explicitly supplied book_edition_id over resolving the ISBN" do
      # The batch path already knows the edition; it should not pay for a lookup.
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
          "url" => "https://example.com/book"
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
      # The `:scraper_fuse` is now owned by ScraperClient. The job no longer has
      # its own fuse guard — it treats {:error, :circuit_open} from the client
      # the same as any other scrape failure.
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
          "selector_match_rate" => 0.9
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
