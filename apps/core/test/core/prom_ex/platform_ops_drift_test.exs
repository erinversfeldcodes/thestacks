defmodule Core.PromEx.PlatformOpsDriftTest do
  @moduledoc """
      Drift guard for the platform/ops dashboard-as-code (240,;
      grafana/platform_ops.json). Unlike the single-domain dashboards, this
      one spans many prefixes (`stacks_rate_limit_`, `stacks_events_`,
      `stacks_fuse_`, `stacks_repo_`, `stacks_router_`, `stacks_upload_`), so
      lock-step is asserted against the FULL registered set. Renames blanking
      panels or new ops families shipping invisible both fail CI.
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

  describe "drift: the NEW trusted-client-IP-source family has a panel" do
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
