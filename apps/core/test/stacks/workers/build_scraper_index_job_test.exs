defmodule Stacks.Workers.BuildScraperIndexJobTest do
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Workers.BuildScraperIndexJob

  describe "fan-out" do
    test "enqueues one job per store observed to need an index" do
      needs =
        insert(:bookstore,
          scraper_module: "za/wordsworth",
          lookup_mode: "local_index",
          isbn_location: "sku"
        )

      insert(:bookstore,
        scraper_module: "za/exclusive_books",
        lookup_mode: "direct",
        isbn_location: "handle"
      )

      assert :ok = perform_job(BuildScraperIndexJob, %{})

      assert_enqueued(worker: BuildScraperIndexJob, args: %{store: needs.scraper_module})
      assert length(all_enqueued(worker: BuildScraperIndexJob)) == 1
    end

    test "skips a store with no ISBN anywhere, which cannot be indexed at all" do
      insert(:bookstore,
        scraper_module: "za/ikes_books",
        lookup_mode: "local_index",
        isbn_location: "none"
      )

      assert :ok = perform_job(BuildScraperIndexJob, %{})
      refute_enqueued(worker: BuildScraperIndexJob)
    end

    test "skips a store with no observation yet" do
      insert(:bookstore, scraper_module: "za/clarkes_books", lookup_mode: nil)

      assert :ok = perform_job(BuildScraperIndexJob, %{})
      refute_enqueued(worker: BuildScraperIndexJob)
    end

    test "is a no-op when nothing needs an index" do
      assert :ok = perform_job(BuildScraperIndexJob, %{})
      refute_enqueued(worker: BuildScraperIndexJob)
    end
  end

  describe "building one store" do
    test "succeeds when the service reports an entry count" do
      assert :ok = perform_job(BuildScraperIndexJob, %{store: "za/wordsworth"})
    end

    test "returns an error so Oban retries when the build fails" do
      Application.put_env(:core, :mock_index_build_result, {:error, :timeout})
      on_exit(fn -> Application.delete_env(:core, :mock_index_build_result) end)

      assert {:error, :timeout} = perform_job(BuildScraperIndexJob, %{store: "za/wordsworth"})
    end
  end
end
