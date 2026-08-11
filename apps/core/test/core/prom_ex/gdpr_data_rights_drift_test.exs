defmodule Core.PromEx.GdprDataRightsDriftTest do
  @moduledoc """
  Drift guard for the GDPR data-rights dashboard-as-code (Issue #238, epic
  #231). Mirrors `Core.PromEx.AuthSecurityDriftTest` (the #237 guard) but
  scoped to `grafana/gdpr_data_rights.json`.

  Proves the dashboard stays in lock-step with the metrics the code actually
  registers, so CI fails on either kind of drift:

    * a panel that queries a metric name **not registered** by
      `Core.PromEx.Plugins.Stacks` (a rename that would silently blank the
      panel), OR
    * a registered **GDPR family** (export/deletion outcomes + the new latency
      distributions, consent grant/revoke, image expired/stuck/orphan, audit
      write + the new audit-read counter) with **no panel** (an invisible
      metric).

  Registered names are read from the plugin at runtime (never hard-coded): the
  exported Prometheus family name for a `Telemetry.Metrics` metric is its
  `name` list joined by `_`, exactly how the plugin's `[:stacks, :gdpr, :audit,
  :read, :count, :total]` becomes `stacks_gdpr_audit_read_count_total`.

  Distributions differ from counters on the wire: a `distribution` named
  `[:stacks, :gdpr, :export, :duration, :milliseconds]` is exported by
  TelemetryMetricsPrometheus as three series suffixed `_bucket` / `_sum` /
  `_count` under the base name `stacks_gdpr_export_duration_milliseconds`.
  Panels query the `_bucket` variant (for `histogram_quantile`), so referenced
  names are normalised back to that registered base before comparison.
  """

  use ExUnit.Case, async: true

  alias Core.PromEx.Plugins.Stacks, as: StacksPlugin

  @dashboard_relative_path "grafana/gdpr_data_rights.json"

  @gdpr_prefix "stacks_gdpr_"

  @new_metric_families [
    "stacks_gdpr_export_duration_milliseconds",
    "stacks_gdpr_deletion_duration_milliseconds",
    "stacks_gdpr_audit_read_count_total"
  ]

  @histogram_suffixes ["_bucket", "_sum", "_count"]

  defp dashboard_path,
    do: Application.app_dir(:core, Path.join("priv", @dashboard_relative_path))

  defp registered_families do
    StacksPlugin.event_metrics([])
    |> Enum.flat_map(& &1.metrics)
    |> Enum.map(fn metric -> metric.name |> Enum.join("_") end)
    |> MapSet.new()
  end

  defp all_panels(%{"panels" => panels}) when is_list(panels) do
    Enum.flat_map(panels, fn panel -> [panel | all_panels(panel)] end)
  end

  defp all_panels(_), do: []

  defp data_panels(dashboard) do
    dashboard
    |> all_panels()
    |> Enum.reject(&(&1["type"] == "row"))
  end

  defp decoded_dashboard do
    dashboard_path() |> File.read!() |> Jason.decode!()
  end

  defp normalise(name) do
    Enum.find_value(@histogram_suffixes, name, fn suffix ->
      if String.ends_with?(name, suffix), do: String.trim_trailing(name, suffix)
    end)
  end

  defp panel_metric_names(dashboard) do
    for panel <- data_panels(dashboard),
        target <- panel["targets"] || [],
        expr = target["expr"],
        is_binary(expr),
        match <- Regex.scan(~r/stacks_[a-zA-Z0-9_]+/, expr),
        name <- match,
        into: MapSet.new() do
      normalise(name)
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

  describe "drift: every registered GDPR family has a panel" do
    test "each registered stacks_gdpr_* family is queried by >=1 panel" do
      registered = registered_families()
      referenced = panel_metric_names(decoded_dashboard())

      gdpr_families =
        registered
        |> Enum.filter(&String.starts_with?(&1, @gdpr_prefix))
        |> MapSet.new()

      assert MapSet.size(gdpr_families) > 0,
             "expected registered families under prefix #{inspect(@gdpr_prefix)}, " <>
               "registered: " <> inspect(Enum.sort(MapSet.to_list(registered)))

      missing = MapSet.difference(gdpr_families, referenced)

      assert MapSet.size(missing) == 0,
             "these GDPR metric families have no dashboard panel (invisible metric): " <>
               inspect(MapSet.to_list(missing))
    end
  end

  describe "drift: the two NEW #238 gap metrics are each on a panel" do
    test "export/deletion latency distributions + audit-read counter are queried and registered" do
      registered = registered_families()
      referenced = panel_metric_names(decoded_dashboard())

      for family <- @new_metric_families do
        assert MapSet.member?(registered, family),
               "expected #{inspect(family)} to be registered by Core.PromEx.Plugins.Stacks; " <>
                 "registered: " <> inspect(Enum.sort(MapSet.to_list(registered)))

        assert MapSet.member?(referenced, family),
               "expected the new #238 metric #{inspect(family)} to be queried by a panel; " <>
                 "referenced: " <> inspect(Enum.sort(MapSet.to_list(referenced)))
      end
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
