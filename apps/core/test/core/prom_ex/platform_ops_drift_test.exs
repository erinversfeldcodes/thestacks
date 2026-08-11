defmodule Core.PromEx.PlatformOpsDriftTest do
  @moduledoc """
  Drift guard for the platform / ops dashboard-as-code (Issue #240, epic
  #231). Mirrors `Core.PromEx.GdprDataRightsDriftTest` (the #238 guard) but
  scoped to `grafana/platform_ops.json`.

  Unlike the single-domain dashboards (#237/#238/#239), this one visualises
  families across MANY prefixes — `stacks_rate_limit_`, `stacks_events_`,
  `stacks_fuse_`, `stacks_repo_`, `stacks_router_`, `stacks_upload_` — so the
  lock-step is asserted against the FULL registered set (like
  `Core.PromEx.DashboardDriftTest` derives `registered_families`), NOT a narrow
  prefix. CI fails on either kind of drift:

    * a panel that queries a `stacks_*` metric name **not registered** by
      `Core.PromEx.Plugins.Stacks` (a rename that would silently blank the
      panel), OR
    * the NEW #240 `stacks_rate_limit_client_ip` trusted-client-IP-source
      family with **no panel** (an invisible metric — the whole point of the
      issue).

  This intentionally does NOT assert the reverse "every registered family has a
  panel" direction: the registered set spans auth/gdpr/moderation/etc. families
  that live on OTHER dashboards, so a full-reverse lock-step here would be
  wrong. `Core.PromEx.DashboardDriftTest` (#228) owns the moderation/age-gate
  reverse lock-step and is left untouched.

  PromEx-builtin metrics (Ecto/Phoenix/Beam/Oban plugins) are non-`stacks_`
  names; the `stacks_[a-zA-Z0-9_]+` panel-scan regex below naturally EXCLUDES
  them, so they are out of the lock-step (they are not in the Stacks plugin's
  registered set). This dashboard queries only `stacks_*` families, so no
  builtin exclusion list is needed.

  Registered names are read from the plugin at runtime (never hard-coded): the
  exported Prometheus family name for a `Telemetry.Metrics` metric is its
  `name` list joined by `_`, exactly how the plugin's `[:stacks, :rate_limit,
  :client_ip, :count, :total]` becomes
  `stacks_rate_limit_client_ip_count_total`.

  Distributions differ from counters on the wire: a `distribution` named
  `[:stacks, :repo, :query, :duration, :milliseconds]` is exported by
  TelemetryMetricsPrometheus as three series suffixed `_bucket` / `_sum` /
  `_count` under the base name `stacks_repo_query_duration_milliseconds`.
  Panels query the `_bucket` variant (for `histogram_quantile`), so referenced
  names are normalised back to that registered base before comparison.
  """

  use ExUnit.Case, async: true

  alias Core.PromEx.Plugins.Stacks, as: StacksPlugin

  @dashboard_relative_path "grafana/platform_ops.json"

  @new_family "stacks_rate_limit_client_ip_count_total"

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

  describe "drift: panels reference only registered metrics (full registered set)" do
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

  describe "drift: the NEW #240 trusted-client-IP-source family has a panel" do
    test "stacks_rate_limit_client_ip is both registered and queried by >=1 panel" do
      registered = registered_families()
      referenced = panel_metric_names(decoded_dashboard())

      assert MapSet.member?(registered, @new_family),
             "expected #{inspect(@new_family)} to be registered by Core.PromEx.Plugins.Stacks; " <>
               "registered: " <> inspect(Enum.sort(MapSet.to_list(registered)))

      assert MapSet.member?(referenced, @new_family),
             "expected the new #240 metric #{inspect(@new_family)} to be queried by a panel; " <>
               "referenced: " <> inspect(Enum.sort(MapSet.to_list(referenced)))
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
