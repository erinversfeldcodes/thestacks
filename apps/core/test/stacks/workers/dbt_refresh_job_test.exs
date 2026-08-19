defmodule Stacks.Workers.DbtRefreshJobTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  alias Stacks.Workers.DbtRefreshHandler
  alias Stacks.Workers.DbtRefreshJob
  alias Stacks.Workers.MockDbtRunner

  describe "DbtRefreshJob selective refresh" do
    test "passes two models as a single space-joined --select value" do
      assert :ok =
               perform_job(DbtRefreshJob, %{
                 "models" => ["int_price_trends", "mart_book_prices"]
               })

      # dbt reads one selector list per --select. A model in its own argv slot
      # is a positional argument, which dbt rejects outright.
      assert MockDbtRunner.last_args() ==
               ["run", "--select", "int_price_trends mart_book_prices"]
    end

    test "passes three models as a single space-joined --select value" do
      assert :ok =
               perform_job(DbtRefreshJob, %{
                 "models" => ["int_blog_engagement", "mart_blog_activity", "mart_system_health"]
               })

      assert MockDbtRunner.last_args() ==
               [
                 "run",
                 "--select",
                 "int_blog_engagement mart_blog_activity mart_system_health"
               ]
    end

    test "passes a single model unchanged" do
      assert :ok = perform_job(DbtRefreshJob, %{"models" => ["mart_community_read_count"]})

      assert MockDbtRunner.last_args() == ["run", "--select", "mart_community_read_count"]
    end

    test "fails loudly when the runner reports an error" do
      Process.put(:mock_dbt_result, {:error, "Database Error in model int_price_trends"})

      assert {:error, "Database Error in model int_price_trends"} =
               perform_job(DbtRefreshJob, %{
                 "models" => ["int_price_trends", "mart_book_prices"]
               })
    end

    test "fails loudly rather than invoking dbt with an empty selector" do
      assert {:error, _} = perform_job(DbtRefreshJob, %{"models" => []})

      refute MockDbtRunner.last_args()
    end
  end

  describe "DbtRefreshJob full refresh" do
    test "calls runner with run only" do
      assert :ok = perform_job(DbtRefreshJob, %{"full" => true})

      assert MockDbtRunner.last_args() == ["run"]
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

    test "maps blog.post_published to correct models" do
      event = %{event_type: "blog.post_published", aggregate_id: "test", payload: %{}}
      assert :ok = DbtRefreshHandler.handle_event(event)

      assert_enqueued(
        worker: DbtRefreshJob,
        args: %{models: ["int_blog_engagement", "mart_blog_activity"]}
      )
    end

    test "maps blog.post_updated to correct models" do
      event = %{event_type: "blog.post_updated", aggregate_id: "test", payload: %{}}
      assert :ok = DbtRefreshHandler.handle_event(event)

      assert_enqueued(
        worker: DbtRefreshJob,
        args: %{models: ["int_blog_engagement", "mart_blog_activity"]}
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
