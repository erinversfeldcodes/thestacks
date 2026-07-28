defmodule Stacks.Workers.BuildScraperIndexJobTest do
  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Workers.BuildScraperIndexJob

  describe "fan-out" do
    test "enqueues one job per store observed to need an index" do
      # Per store, not one long sweep: a failure against one shop must not lose the
      # others' work, and Oban's retry then applies per store.
      needs =
        insert(:bookstore,
          scraper_module: "za/wordsworth",
          lookup_mode: "local_index",
          isbn_location: "sku"
        )

      # Addressable by ISBN directly — no index required.
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
      # Ike's Books had no ISBN on any of 50 sampled products. Sweeping its catalogue
      # would spend requests to build an empty index; fuzzy title matching is its only
      # path and that is not this sweep's job.
      insert(:bookstore,
        scraper_module: "za/ikes_books",
        lookup_mode: "local_index",
        isbn_location: "none"
      )

      assert :ok = perform_job(BuildScraperIndexJob, %{})
      refute_enqueued(worker: BuildScraperIndexJob)
    end

    test "skips a store with no observation yet" do
      # Capability is derived on the next scrape. Sweeping a whole catalogue on a guess
      # is the bulk harvesting this design exists to avoid.
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
      # A sweep can lose to a rate limit or a transient network fault. Retrying is the
      # right answer; swallowing it would leave the store answering IndexRequired with
      # nothing recorded to explain why.
      Application.put_env(:core, :mock_index_build_result, {:error, :timeout})
      on_exit(fn -> Application.delete_env(:core, :mock_index_build_result) end)

      assert {:error, :timeout} = perform_job(BuildScraperIndexJob, %{store: "za/wordsworth"})
    end
  end
end
