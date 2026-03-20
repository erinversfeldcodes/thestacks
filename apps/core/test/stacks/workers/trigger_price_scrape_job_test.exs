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
      book = insert(:book)
      store = insert(:bookstore)
      _edition = insert(:book_edition, book: book, isbn: "9780743273565")

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

      job = TriggerPriceScrapeJob.new(%{isbn: "9780743273565", book_id: book.id})
      assert :ok = perform_job(TriggerPriceScrapeJob, job.changes.args)
    end

    test "returns ok when no stores configured" do
      book = insert(:book)
      job = TriggerPriceScrapeJob.new(%{isbn: "9780743273565", book_id: book.id})
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

  describe "circuit breaker" do
    test "returns error when fuse is blown" do
      book = insert(:book)
      _store = insert(:bookstore)

      # Install and blow the fuse
      :fuse.install(:scraper_fuse, {{:standard, 1, 1_000}, {:reset, 60_000}})
      :fuse.melt(:scraper_fuse)
      :fuse.melt(:scraper_fuse)

      job = TriggerPriceScrapeJob.new(%{isbn: "9780743273565", book_id: book.id})
      assert {:error, :circuit_open} = perform_job(TriggerPriceScrapeJob, job.changes.args)

      # Clean up
      :fuse.remove(:scraper_fuse)
    end
  end

  describe "scraper failure" do
    test "melts fuse on scraper error and returns ok when not all fail" do
      book = insert(:book)
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

      job = TriggerPriceScrapeJob.new(%{isbn: "9780743273565", book_id: book.id})
      assert :ok = perform_job(TriggerPriceScrapeJob, job.changes.args)
    end

    test "returns error when all scrape requests fail" do
      book = insert(:book)
      store = insert(:bookstore)

      MockScraperClient.put_response("9780743273565", store.scraper_module, {:error, :timeout})

      job = TriggerPriceScrapeJob.new(%{isbn: "9780743273565", book_id: book.id})

      assert {:error, "all scrape requests failed"} =
               perform_job(TriggerPriceScrapeJob, job.changes.args)
    end
  end
end
