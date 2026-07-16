defmodule Core.PromEx.DashboardDriftTest do
  @moduledoc """
  Drift guard for the moderation + age-gate dashboard-as-code (Issue #230).

  The dashboard JSON checked into `apps/core/priv/grafana/` visualises the
  #228 moderation-funnel and age-gate counters. This test proves the
  dashboard stays in lock-step with the metrics the code actually
  registers, so CI fails on either kind of drift:

    * a panel that queries a metric name **no longer registered** by
      `Core.PromEx.Plugins.Stacks` (a rename that would silently blank the
      panel), OR
    * a #228 moderation/age-gate metric family with **no panel** (an
      invisible metric).

  The registered names are read from the plugin at runtime (never
  hard-coded) so this test cannot itself drift: the exported Prometheus
  family name for a `Telemetry.Metrics` metric is its `name` list joined by
  `_` (see TelemetryMetricsPrometheus.Core.Exporter.format_name/1), which
  is exactly how the plugin's `[:stacks, :moderation, :classification,
  :count, :total]` becomes `stacks_moderation_classification_count_total`.
  """

  use ExUnit.Case, async: true

  alias Core.PromEx.Plugins.Stacks, as: StacksPlugin

  @dashboard_relative_path "grafana/moderation_agegate.json"

  # #228 families live under these Prometheus name prefixes.
  @issue_228_prefixes ["stacks_moderation_", "stacks_age_gate_", "stacks_age_verification_"]

  defp dashboard_path,
    do: Application.app_dir(:core, Path.join("priv", @dashboard_relative_path))

  # Registered Prometheus family names, derived from the plugin's declared
  # Telemetry.Metrics structs — the same join TelemetryMetricsPrometheus uses.
  defp registered_families do
    StacksPlugin.event_metrics([])
    |> Enum.flat_map(& &1.metrics)
    |> Enum.map(fn metric -> metric.name |> Enum.join("_") end)
    |> MapSet.new()
  end

  # Recursively collect every panel (including panels nested inside Grafana
  # "row" panels) from a decoded dashboard.
  defp all_panels(%{"panels" => panels}) when is_list(panels) do
    Enum.flat_map(panels, fn panel ->
      [panel | all_panels(panel)]
    end)
  end

  defp all_panels(_), do: []

  # Only panels that actually render data (skip "row" separators).
  defp data_panels(dashboard) do
    dashboard
    |> all_panels()
    |> Enum.reject(&(&1["type"] == "row"))
  end

  defp decoded_dashboard do
    dashboard_path() |> File.read!() |> Jason.decode!()
  end

  # All `stacks_*` metric names referenced by any panel target `expr`.
  defp panel_metric_names(dashboard) do
    for panel <- data_panels(dashboard),
        target <- panel["targets"] || [],
        expr = target["expr"],
        is_binary(expr),
        match <- Regex.scan(~r/stacks_[a-zA-Z0-9_]+/, expr),
        name <- match,
        into: MapSet.new() do
      name
    end
  end

  describe "registration" do
    test "the dashboard is registered via Core.PromEx.dashboards/0 with the {:core, path} form" do
      assert {:core, @dashboard_relative_path} in Core.PromEx.dashboards(),
             "expected Core.PromEx.dashboards/0 to register " <>
               "{:core, #{inspect(@dashboard_relative_path)}}, got: " <>
               inspect(Core.PromEx.dashboards())
    end

    test "the registered dashboard JSON file exists and is valid JSON" do
      assert File.exists?(dashboard_path()),
             "expected dashboard JSON at #{dashboard_path()}"

      assert %{"panels" => panels} = decoded_dashboard()
      assert is_list(panels) and panels != []
    end
  end

  describe "drift: panels reference only registered metrics" do
    test "every stacks_* metric a panel queries is a registered metric family" do
      registered = registered_families()
      referenced = panel_metric_names(decoded_dashboard())

      assert referenced != MapSet.new(), "expected the dashboard to query at least one metric"

      unknown = MapSet.difference(referenced, registered)

      assert MapSet.size(unknown) == 0,
             "dashboard panels reference metric(s) not registered by " <>
               "Core.PromEx.Plugins.Stacks (renamed or removed?): " <>
               inspect(MapSet.to_list(unknown))
    end
  end

  describe "drift: every #228 moderation/age-gate metric has a panel" do
    test "each registered moderation/age-gate family is queried by at least one panel" do
      registered = registered_families()
      referenced = panel_metric_names(decoded_dashboard())

      issue_228 =
        registered
        |> Enum.filter(fn name ->
          Enum.any?(@issue_228_prefixes, &String.starts_with?(name, &1))
        end)
        |> MapSet.new()

      # Sanity: the six #228 families are actually registered (guards against
      # the plugin being gutted without this test noticing).
      assert MapSet.size(issue_228) == 6,
             "expected 6 registered #228 moderation/age-gate families, found: " <>
               inspect(MapSet.to_list(issue_228))

      missing = MapSet.difference(issue_228, referenced)

      assert MapSet.size(missing) == 0,
             "these #228 metric families have no dashboard panel (invisible metric): " <>
               inspect(MapSet.to_list(missing))
    end
  end

  describe "every panel teaches" do
    test "every data panel carries a non-trivial teaching description" do
      panels = data_panels(decoded_dashboard())
      assert panels != [], "expected at least one data panel"

      undescribed =
        Enum.filter(panels, fn panel ->
          desc = to_string(panel["description"] || "")
          String.trim(desc) == "" or String.length(desc) < 40
        end)

      assert undescribed == [],
             "these panels lack a teaching description (what/how/means/spike-drop): " <>
               inspect(Enum.map(undescribed, & &1["title"]))
    end
  end
end
