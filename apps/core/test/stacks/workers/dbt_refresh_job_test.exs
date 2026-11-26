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
      # Models that EXIST. The job forwards whatever list it is handed without
      # checking the models are real, so this case used to be written against
      # three models that were later deleted — it kept passing and quietly
      # described a warehouse that no longer existed. No current event maps to
      # three models; the three-argument join is still worth pinning because the
      # joining, not the mapping, is what this asserts.
      assert :ok =
               perform_job(DbtRefreshJob, %{
                 "models" => [
                   "int_book_detail_view",
                   "mart_platform_searchable",
                   "mart_cost_tracking"
                 ]
               })

      assert MockDbtRunner.last_args() ==
               [
                 "run",
                 "--select",
                 "int_book_detail_view mart_platform_searchable mart_cost_tracking"
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

    # ⚠️ These five used to assert a refresh. Every dbt model they refreshed was
    # deleted as an orphan — `mart_system_health`, the
    # `int_blog_engagement`/`mart_blog_activity` pair, and the
    # `int_review_sentiment`/`mart_book_reviews` pair — so the handler has
    # nothing to enqueue for them.
    #
    # Asserted as `refute_enqueued` rather than deleted outright, because
    # "enqueues nothing" is the new behaviour and the interesting failure is the
    # OTHER direction: a future reader re-adding one of these mappings without
    # restoring the model. ⚠️ What makes that direction worth a test is the
    # failure mode it has — **dbt exits 0 on a selector that matches nothing.**
    # Verified: `dbt ls --select mart_blog_activity` exits 0 with "does not match
    # any enabled nodes / No nodes selected!". So a mapping naming a deleted
    # model produces a GREEN dbt run that refreshes nothing, and the warehouse
    # goes stale behind it silently. Nothing else in the stack catches that:
    # no gate reads `@model_mapping` against the models on disk.
    #
    # (An earlier version of this comment claimed the guard was
    # `DbtRefreshJob`'s "selective refresh requested with no models" log. That
    # was wrong in a way worth recording: that clause matches `models: []` only
    # — an EMPTY list — and it returns `{:error, _}`, which is a loud failure
    # already asserted 60 lines above. It never fires for a non-empty list of
    # names that happen not to exist, which is precisely this case.)
    #
    # `blog.post_published` is still handled — by `BlogAssociationHandler` — so
    # only its dbt refresh is gone. `blog.post_updated`, `blog.post_deleted` and
    # `source_health.recorded` lost their only handler and are recorded in the
    # registry's @unsubscribed list with their reasons.
    # `enrichment.reviews_scraped` is the one that is STILL SUBSCRIBED by owner
    # ruling and now no-ops — so it is the only live-wiring assertion here, and
    # it gets its own name rather than sharing a failure message with four dead
    # ones.
    for event_type <- [
          "source_health.recorded",
          "blog.post_published",
          "blog.post_updated",
          "blog.post_deleted",
          "enrichment.reviews_scraped"
        ] do
      test "#{event_type} enqueues no dbt refresh, and does not raise" do
        event = %{event_type: unquote(event_type), aggregate_id: "test", payload: %{}}

        assert :ok = DbtRefreshHandler.handle_event(event)

        refute_enqueued(worker: DbtRefreshJob)
      end
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
