defmodule Core.PromEx.DashboardStandardTest do
  @moduledoc """
  Enforces the "every panel teaches" dashboard standard (Issue #233,
  `docs/agents/standards/dashboards.md`) across **every** ops dashboard.

  Unlike `Core.PromEx.DashboardDriftTest` — which guards metric ↔ panel
  lock-step for the single #230 moderation/age-gate dashboard — this test
  reads the dashboard list from `Core.PromEx.dashboards/0` at runtime and
  asserts that **every** registered dashboard's data panels carry a
  non-trivial teaching description. New dashboards (#236–#240) inherit the
  rule the moment they are added to `dashboards/0`, with no edit here.

  A "data panel" is any panel that renders a series; Grafana `row`
  separators are layout-only and exempt. A description must be long enough
  to carry the four teaching elements (what · how · means · spike/drop);
  the same `< 40` chars threshold used by `DashboardDriftTest` treats a
  stub as missing.
  """

  use ExUnit.Case, async: true

  # Keep this in lock-step with DashboardDriftTest's teaching-description
  # threshold: a description shorter than this cannot carry what/how/means/
  # spike-drop and is treated as missing.
  @min_description_length 40

  defp dashboard_path(relative),
    do: Application.app_dir(:core, Path.join("priv", relative))

  # Recursively collect every panel, including panels nested inside Grafana
  # "row" panels.
  defp all_panels(%{"panels" => panels}) when is_list(panels) do
    Enum.flat_map(panels, fn panel -> [panel | all_panels(panel)] end)
  end

  defp all_panels(_), do: []

  # Only panels that render data (skip "row" separators).
  defp data_panels(dashboard) do
    dashboard
    |> all_panels()
    |> Enum.reject(&(&1["type"] == "row"))
  end

  defp undescribed_panels(dashboard) do
    dashboard
    |> data_panels()
    |> Enum.filter(fn panel ->
      desc = to_string(panel["description"] || "")
      String.trim(desc) == "" or String.length(desc) < @min_description_length
    end)
  end

  # The registered dashboards, normalised to their priv-relative JSON path.
  # `dashboards/0` uses the `{:core, path}` form (see Core.PromEx).
  defp registered_dashboard_paths do
    Enum.map(Core.PromEx.dashboards(), fn
      {:core, relative} -> relative
      other -> flunk("unexpected dashboards/0 entry (expected {:core, path}): #{inspect(other)}")
    end)
  end

  describe "every registered dashboard is self-explanatory" do
    test "dashboards/0 registers at least one dashboard" do
      assert registered_dashboard_paths() != [],
             "expected Core.PromEx.dashboards/0 to register at least one dashboard"
    end

    test "every data panel of every registered dashboard carries a teaching description" do
      for relative <- registered_dashboard_paths() do
        path = dashboard_path(relative)

        assert File.exists?(path),
               "registered dashboard JSON missing on disk: #{path}"

        dashboard = path |> File.read!() |> Jason.decode!()

        panels = data_panels(dashboard)

        assert panels != [],
               "#{relative}: expected at least one data panel (row separators are exempt)"

        undescribed = undescribed_panels(dashboard)

        assert undescribed == [],
               "#{relative}: these data panels lack a teaching description " <>
                 "(what · how · means · spike/drop — see docs/agents/standards/dashboards.md): " <>
                 inspect(Enum.map(undescribed, &(&1["title"] || &1["id"])))
      end
    end
  end
end
