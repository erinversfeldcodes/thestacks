defmodule Stacks.Workers.DbtRefreshJobTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  alias Stacks.Workers.DbtRefreshHandler
  alias Stacks.Workers.DbtRefreshJob

  describe "DbtRefreshJob selective refresh" do
    test "calls runner with --select and model names" do
      assert :ok =
               perform_job(DbtRefreshJob, %{
                 "models" => ["mart_book_prices", "int_price_trends"]
               })
    end
  end

  describe "DbtRefreshJob full refresh" do
    test "calls runner with run only" do
      assert :ok = perform_job(DbtRefreshJob, %{"full" => true})
    end
  end

  describe "DbtRefreshJob error handling" do
    test "returns error when runner fails" do
      Process.put(:mock_dbt_result, {:error, "dbt compilation error"})

      assert {:error, "dbt compilation error"} =
               perform_job(DbtRefreshJob, %{"full" => true})
    end
  end

  describe "DbtRefreshHandler" do
    test "maps enrichment.prices_scraped to correct models" do
      event = %{event_type: "enrichment.prices_scraped", aggregate_id: "test", payload: %{}}
      assert :ok = DbtRefreshHandler.handle_event(event)

      assert_enqueued(
        worker: DbtRefreshJob,
        args: %{models: ["int_price_trends", "mart_book_prices"]}
      )
    end

    test "maps placement.created to correct models" do
      event = %{event_type: "placement.created", aggregate_id: "test", payload: %{}}
      assert :ok = DbtRefreshHandler.handle_event(event)

      assert_enqueued(
        worker: DbtRefreshJob,
        args: %{models: ["mart_community_read_count", "mart_platform_searchable"]}
      )
    end

    test "maps placement.moved to correct models" do
      event = %{event_type: "placement.moved", aggregate_id: "test", payload: %{}}
      assert :ok = DbtRefreshHandler.handle_event(event)

      assert_enqueued(
        worker: DbtRefreshJob,
        args: %{models: ["mart_community_read_count"]}
      )
    end

    test "maps source_health.recorded to correct models" do
      event = %{event_type: "source_health.recorded", aggregate_id: "test", payload: %{}}
      assert :ok = DbtRefreshHandler.handle_event(event)

      assert_enqueued(
        worker: DbtRefreshJob,
        args: %{models: ["mart_system_health"]}
      )
    end

    test "ignores unmapped events" do
      event = %{event_type: "user.registered", aggregate_id: "test", payload: %{}}
      assert :ok = DbtRefreshHandler.handle_event(event)

      refute_enqueued(worker: DbtRefreshJob)
    end

    test "ignores events with no event_type match" do
      event = %{event_type: "unknown.event", aggregate_id: "test", payload: %{}}
      assert :ok = DbtRefreshHandler.handle_event(event)

      refute_enqueued(worker: DbtRefreshJob)
    end
  end
end
