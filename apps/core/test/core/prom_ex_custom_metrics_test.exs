defmodule Core.PromExCustomMetricsTest do
  @moduledoc """
  Regression test for Issue #139: custom `stacks_*` telemetry events
  must be exported via PromEx so the SLO gate scraper
  (`scripts/check-slo-gate.sh`) sees real values at `/internal/metrics`.

  The parser expects these specific Prometheus metric family names:
    * `stacks_upload_terminal_count_total`
    * `stacks_router_dispatch_stop_duration_milliseconds_bucket` (plus `_sum` / `_count`)
    * `stacks_fuse_state_state`

  `Core.PromEx` is started by the application supervisor
  (`apps/core/lib/core/application.ex`) for the test environment, so we
  emit events against the already-running PromEx and scrape the output
  via `PromEx.get_metrics/1`.
  """

  # async: false — PromEx state is global and we assert on scraped output.
  use ExUnit.Case, async: false

  setup do
    # Let the scraper drain any previously emitted events before asserting.
    :ok
  end

  test "PromEx exports custom stacks_* metrics the SLO gate scraper reads" do
    # Emit a representative sample of each custom event so PromEx records a
    # non-empty series for each.
    :telemetry.execute(
      [:stacks, :upload, :terminal],
      %{count: 1},
      %{outcome: :resolved}
    )

    :telemetry.execute(
      [:stacks, :router_dispatch, :stop],
      %{duration: System.convert_time_unit(42, :millisecond, :native)},
      %{route: "/api/health", route_group: :health}
    )

    :telemetry.execute(
      [:stacks, :fuse, :state],
      %{state: 1},
      %{fuse_name: :vision_fuse}
    )

    # Give PromEx's telemetry handler a moment to process the ETS writes.
    Process.sleep(50)

    output = PromEx.get_metrics(Core.PromEx)

    refute output == :prom_ex_down, "Core.PromEx must be running for this test"

    assert output =~ "stacks_upload_terminal_count_total",
           "expected stacks_upload_terminal_count_total in PromEx output, got:\n#{output}"

    assert output =~ "stacks_router_dispatch_stop_duration_milliseconds",
           "expected stacks_router_dispatch_stop_duration_milliseconds_{bucket,sum,count} in PromEx output, got:\n#{output}"

    assert output =~ "stacks_fuse_state_state",
           "expected stacks_fuse_state_state in PromEx output, got:\n#{output}"
  end

  # Issue #181: AuthController.refresh/2 emits
  # [:stacks, :auth, :refresh, :revoke_failed] when it fails to revoke the old
  # token during rotation. This test proves the metric is registered in the
  # PromEx plugin AND that emitting the event is picked up by the registered
  # counter — i.e. the emission in the controller branch (covered directly by
  # the auth_controller_test) will be exported as a real, scrapeable series.
  test "PromEx exports the auth refresh revoke-failure counter (Issue #181)" do
    :telemetry.execute(
      [:stacks, :auth, :refresh, :revoke_failed],
      %{count: 1},
      %{}
    )

    # Give PromEx's telemetry handler a moment to process the ETS writes.
    Process.sleep(50)

    output = PromEx.get_metrics(Core.PromEx)

    refute output == :prom_ex_down, "Core.PromEx must be running for this test"

    assert output =~ "stacks_auth_refresh_revoke_failed_count_total",
           "expected stacks_auth_refresh_revoke_failed_count_total in PromEx output, got:\n#{output}"
  end
end
