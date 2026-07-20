defmodule Stacks.Monitoring.SourceHealthCheckTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Monitoring
  alias Stacks.Monitoring.SourceHealthCheck

  describe "change_source_health_check/2" do
    test "is valid with source_name, source_type, and status" do
      changeset =
        Monitoring.change_source_health_check(%SourceHealthCheck{}, %{
          source_name: "my-scraper",
          source_type: "scraper_config",
          status: "healthy",
          consecutive_failures: 0,
          total_successes: 10,
          total_failures: 0
        })

      assert changeset.valid?
    end

    test "is invalid without source_name" do
      changeset =
        Monitoring.change_source_health_check(%SourceHealthCheck{}, %{
          source_type: "scraper_config",
          status: "healthy"
        })

      refute changeset.valid?
      assert %{source_name: [_ | _]} = errors_on(changeset)
    end

    test "is invalid with an unknown source_type" do
      changeset =
        Monitoring.change_source_health_check(%SourceHealthCheck{}, %{
          source_name: "my-scraper",
          source_type: "carrier_pigeon",
          status: "healthy"
        })

      refute changeset.valid?
      assert %{source_type: [_ | _]} = errors_on(changeset)
    end

    test "is invalid with an unknown status" do
      changeset =
        Monitoring.change_source_health_check(%SourceHealthCheck{}, %{
          source_name: "my-scraper",
          source_type: "scraper_config",
          status: "vibing"
        })

      refute changeset.valid?
      assert %{status: [_ | _]} = errors_on(changeset)
    end
  end

  describe "DB constraint smoke test" do
    test "persists a valid source health check" do
      check = insert(:source_health_check)
      assert check.id
      assert check.status == "healthy"
    end

    test "enforces unique constraint on source_name" do
      insert(:source_health_check, source_name: "my-scraper")

      assert {:error, changeset} =
               %SourceHealthCheck{}
               |> Monitoring.change_source_health_check(%{
                 source_name: "my-scraper",
                 source_type: "scraper_config",
                 status: "healthy"
               })
               |> Core.Repo.insert()

      assert %{source_name: [_ | _]} = errors_on(changeset)
    end
  end

  describe "record_success/2" do
    test "creates a new health check on first call" do
      assert {:ok, check} = Monitoring.record_success("test-source", "scraper_config")
      assert check.source_name == "test-source"
      assert check.source_type == "scraper_config"
      assert check.status == "healthy"
      assert check.consecutive_failures == 0
      assert check.total_successes == 1
      assert check.total_failures == 0
      assert check.last_success_at
    end

    test "resets consecutive_failures and increments total_successes" do
      insert(:source_health_check,
        source_name: "flaky-source",
        source_type: "scraper_config",
        consecutive_failures: 5,
        total_successes: 10,
        total_failures: 5,
        status: "degraded"
      )

      assert {:ok, check} = Monitoring.record_success("flaky-source", "scraper_config")
      assert check.consecutive_failures == 0
      assert check.total_successes == 11
      assert check.total_failures == 5
      assert check.status == "healthy"
    end

    test "sets last_success_at to current time" do
      before = DateTime.utc_now()
      assert {:ok, check} = Monitoring.record_success("time-source", "rss_feed")
      assert DateTime.compare(check.last_success_at, before) in [:gt, :eq]
    end
  end

  describe "record_failure/3" do
    test "creates a new health check on first call" do
      assert {:ok, check} =
               Monitoring.record_failure("bad-source", "review_source", "connection refused")

      assert check.source_name == "bad-source"
      assert check.source_type == "review_source"
      assert check.consecutive_failures == 1
      assert check.total_failures == 1
      assert check.total_successes == 0
      assert check.last_failure_reason == "connection refused"
      assert check.status == "healthy"
    end

    test "increments consecutive_failures and total_failures" do
      insert(:source_health_check,
        source_name: "failing-source",
        source_type: "scraper_config",
        consecutive_failures: 2,
        total_successes: 10,
        total_failures: 5,
        status: "healthy"
      )

      assert {:ok, check} =
               Monitoring.record_failure("failing-source", "scraper_config", "timeout")

      assert check.consecutive_failures == 3
      assert check.total_failures == 6
      assert check.total_successes == 10
    end

    test "auto-computes status to degraded at 3 consecutive failures" do
      insert(:source_health_check,
        source_name: "degrading-source",
        source_type: "scraper_config",
        consecutive_failures: 2,
        total_failures: 2,
        status: "healthy"
      )

      assert {:ok, check} =
               Monitoring.record_failure("degrading-source", "scraper_config", "error")

      assert check.status == "degraded"
      assert check.consecutive_failures == 3
    end

    test "auto-computes status to broken at 7 consecutive failures" do
      insert(:source_health_check,
        source_name: "broken-source",
        source_type: "scraper_config",
        consecutive_failures: 6,
        total_failures: 6,
        status: "degraded"
      )

      assert {:ok, check} =
               Monitoring.record_failure("broken-source", "scraper_config", "gone")

      assert check.status == "broken"
      assert check.consecutive_failures == 7
    end

    test "stores the failure reason" do
      assert {:ok, check} =
               Monitoring.record_failure("reason-source", "rss_feed", "HTTP 404")

      assert check.last_failure_reason == "HTTP 404"
    end
  end

  describe "get_or_create/2" do
    test "creates a new record when source_name does not exist" do
      assert {:ok, check} = Monitoring.get_or_create("new-source", "event_source")
      assert check.source_name == "new-source"
      assert check.source_type == "event_source"
      assert check.status == "healthy"
      assert check.consecutive_failures == 0
    end

    test "returns existing record when source_name exists" do
      existing = insert(:source_health_check, source_name: "existing-source")
      assert {:ok, check} = Monitoring.get_or_create("existing-source", "scraper_config")
      assert check.id == existing.id
    end
  end

  describe "list_source_health/0" do
    test "returns rows in the scraper-health wire shape, ordered by source_name" do
      now = DateTime.utc_now()

      insert(:source_health_check,
        source_name: "zeta-source",
        source_type: "rss_feed",
        status: "broken",
        consecutive_failures: 9,
        last_success_at: nil,
        last_failure_at: now
      )

      insert(:source_health_check,
        source_name: "alpha-source",
        source_type: "scraper_config",
        status: "healthy",
        consecutive_failures: 0,
        last_success_at: now,
        last_failure_at: nil
      )

      [first, second] = Monitoring.list_source_health()

      # Ordered by source_name ascending.
      assert first.name == "alpha-source"
      assert second.name == "zeta-source"

      # Exact wire contract the frontend `getSourceHealth` decoder consumes:
      # {name, source_type, status, consecutive_failures, last_success_at, last_failure_at}.
      assert Map.keys(first) |> Enum.sort() == [
               :consecutive_failures,
               :last_failure_at,
               :last_success_at,
               :name,
               :source_type,
               :status
             ]

      # Plain-string source_type/status (not proto enums).
      assert first.source_type == "scraper_config"
      assert first.status == "healthy"
      # ISO8601-or-nil timestamps.
      assert is_binary(first.last_success_at)
      assert first.last_failure_at == nil
    end

    test "returns an empty list when no checks exist" do
      assert Monitoring.list_source_health() == []
    end
  end

  describe "compute_status/1" do
    test "returns healthy for 0-2 failures" do
      assert Monitoring.compute_status(0) == "healthy"
      assert Monitoring.compute_status(1) == "healthy"
      assert Monitoring.compute_status(2) == "healthy"
    end

    test "returns degraded for 3-6 failures" do
      assert Monitoring.compute_status(3) == "degraded"
      assert Monitoring.compute_status(4) == "degraded"
      assert Monitoring.compute_status(5) == "degraded"
      assert Monitoring.compute_status(6) == "degraded"
    end

    test "returns broken for 7+ failures" do
      assert Monitoring.compute_status(7) == "broken"
      assert Monitoring.compute_status(10) == "broken"
      assert Monitoring.compute_status(100) == "broken"
    end
  end
end
