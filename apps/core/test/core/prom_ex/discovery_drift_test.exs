defmodule Core.PromEx.DiscoveryDriftTest do
  @moduledoc """
    Drift guard for the discovery & profiles dashboard-as-code (239,; grafana/discovery.json):
    panels may only query metric families registered by
    `Core.PromEx.Plugins.Stacks`, and every registered 239 discovery family must have
    a panel. Either direction of drift — a renamed metric silently blanking
    a panel, or a new family shipping invisible — fails CI.
  """

  use ExUnit.Case, async: true

  alias Core.PromEx.Plugins.Stacks, as: StacksPlugin

  @dashboard_relative_path "grafana/discovery.json"

  @new_family_prefixes [
    "stacks_search_people",
    "stacks_profile_view",
    "stacks_shelf_browse_capped",
    "stacks_handle_claimed"
  ]

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

  describe "drift: every NEW discovery family has a panel" do
    test "each new people-search / profile-view / shelf-cap / handle-claim family is queried by >=1 panel" do
      registered = registered_families()
      referenced = panel_metric_names(decoded_dashboard())

      for prefix <- @new_family_prefixes do
        registered_matches =
          Enum.filter(registered, &String.starts_with?(&1, prefix))

        assert registered_matches != [],
               "expected a registered family under prefix #{inspect(prefix)}, " <>
                 "registered: " <> inspect(Enum.sort(MapSet.to_list(registered)))

        missing =
          registered_matches
          |> MapSet.new()
          |> MapSet.difference(referenced)

        assert MapSet.size(missing) == 0,
               "these new #239 discovery families have no dashboard panel " <>
                 "(invisible metric): " <> inspect(MapSet.to_list(missing))
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
