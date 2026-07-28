defmodule Stacks.Workers.MatchStoreCatalogueJobTest do
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Workers.MatchStoreCatalogueJob

  describe "store selection" do
    test "selects a store with a product API but no ISBN on any product" do
      # Ike's Books: enumerable, but 0 of 50 sampled products carried an ISBN.
      ikes =
        insert(:bookstore,
          scraper_module: "za/ikes_books",
          price_source: "shopify_products_json",
          isbn_location: "none"
        )

      assert :ok = perform_job(MatchStoreCatalogueJob, %{})
      assert_enqueued(worker: MatchStoreCatalogueJob, args: %{store: ikes.scraper_module})
    end

    test "skips a store whose products do carry ISBNs" do
      # Identifiable by ISBN, so title matching would be strictly worse.
      insert(:bookstore,
        scraper_module: "za/wordsworth",
        price_source: "shopify_products_json",
        isbn_location: "sku"
      )

      assert :ok = perform_job(MatchStoreCatalogueJob, %{})
      refute_enqueued(worker: MatchStoreCatalogueJob)
    end

    test "skips a store with no product API, which cannot be enumerated" do
      # loot.co.za and fortunatefinds.co.za: nothing to sweep, so no titles to match.
      insert(:bookstore,
        scraper_module: "za/loot",
        price_source: "none",
        isbn_location: "none"
      )

      assert :ok = perform_job(MatchStoreCatalogueJob, %{})
      refute_enqueued(worker: MatchStoreCatalogueJob)
    end

    test "skips a store with no observation yet" do
      insert(:bookstore, scraper_module: "za/clarkes_books", price_source: nil)

      assert :ok = perform_job(MatchStoreCatalogueJob, %{})
      refute_enqueued(worker: MatchStoreCatalogueJob)
    end
  end

  describe "sweeping one store" do
    setup do
      start_supervised!(Stacks.Enrichment.PricePipeline)

      store =
        insert(:bookstore,
          scraper_module: "za/ikes_books",
          price_source: "shopify_products_json",
          isbn_location: "none"
        )

      on_exit(fn -> Application.delete_env(:core, :mock_catalogue_titles) end)
      %{store: store}
    end

    test "is a no-op when the shop lists no unmatched titles", %{store: store} do
      Application.put_env(:core, :mock_catalogue_titles, {:ok, []})
      assert :ok = perform_job(MatchStoreCatalogueJob, %{store: store.scraper_module})
    end

    test "returns an error so Oban retries when the sweep fails", %{store: store} do
      # A catalogue sweep can lose to a rate limit or a transient fault. Retrying is
      # right; swallowing would leave the shop silently unpriced.
      Application.put_env(:core, :mock_catalogue_titles, {:error, :timeout})

      assert {:error, :timeout} =
               perform_job(MatchStoreCatalogueJob, %{store: store.scraper_module})
    end

    test "errors on an unknown store rather than sweeping nothing quietly" do
      assert {:error, :unknown_store} =
               perform_job(MatchStoreCatalogueJob, %{store: "za/does_not_exist"})
    end
  end
end
