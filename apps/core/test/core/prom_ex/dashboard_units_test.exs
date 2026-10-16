defmodule Core.PromEx.DashboardUnitsTest do
  @moduledoc """
      The half of dashboard correctness this project did not gate.

      `dashboard_completeness_test.exs` proves a panel QUERIES a metric family
      that exists. Nothing proved that the panel's unit, arithmetic and legend
      describe what the query returns — and two money panels shipped labelled
      `currencyUSD` over a CENTS series, one of them over `rate()`. Grafana
      prefixes `$` to whatever number arrives, so $12.00 of spend rendered as
      `$1200` before the per-second factor even applied. The panel descriptions
      honestly said "in cents"; the axis contradicted them, and the completeness
      test regexes family names out of `expr` and never looks at `unit` at all.

      ⚠️ A unit bug surfaces when an operator reads a 100×-wrong figure during
      an incident, which is the worst available moment to find it.

      Two properties, both read off the dashboard JSON:

        1. A `currencyUSD` panel whose expression names a `_cents` family must
           divide by 100.
        2. A panel with several targets returning DIFFERENT kinds of thing must
           carry per-target unit overrides, or its single `unit` is applied to
           all of them — which is how a refusal COUNT came to render with a `$`.
  """

  use ExUnit.Case, async: true

  @dashboards ~w(platform_ops.json moderation_agegate.json)

  defp dashboard_path(name),
    do: Application.app_dir(:core, Path.join("priv/grafana", name))

  defp load(name) do
    case File.read(dashboard_path(name)) do
      {:ok, body} -> Jason.decode!(body)
      {:error, _} -> nil
    end
  end

  defp all_panels(%{"panels" => panels}) when is_list(panels),
    do: Enum.flat_map(panels, fn panel -> [panel | all_panels(panel)] end)

  defp all_panels(_), do: []

  defp data_panels(dashboard),
    do: dashboard |> all_panels() |> Enum.reject(&(&1["type"] == "row"))

  defp unit(panel), do: get_in(panel, ["fieldConfig", "defaults", "unit"]) || ""
  defp overrides(panel), do: get_in(panel, ["fieldConfig", "overrides"]) || []

  defp exprs(panel),
    do: for(target <- panel["targets"] || [], do: target["expr"] || "")

  defp label(dashboard_name, panel),
    do: "#{dashboard_name} panel #{panel["id"]} (#{panel["title"]})"

  # What a target returns, coarsely: money if it names a `_cents` family, a rate
  # if it is wrapped in `rate(`, otherwise a plain count. Coarse on purpose —
  # the property under test is "these are not all the same kind", and a finer
  # taxonomy would make the gate argue about cases it cannot settle.
  defp target_kind(expr) do
    cond do
      String.contains?(expr, "_cents") -> :money
      String.contains?(expr, "rate(") -> :rate
      true -> :count
    end
  end

  describe "money panels" do
    test "a currencyUSD panel over a cents family divides by 100" do
      offenders =
        for name <- @dashboards,
            dashboard = load(name),
            dashboard != nil,
            panel <- data_panels(dashboard),
            unit(panel) == "currencyUSD",
            expr <- exprs(panel),
            String.contains?(expr, "_cents"),
            not String.contains?(expr, "/ 100") and not String.contains?(expr, "/100"),
            do: "#{label(name, panel)}: #{expr}"

      assert offenders == [],
             "panel(s) labelled currencyUSD query a _cents family without dividing by 100, so " <>
               "Grafana renders a hundred times the real figure with a `$` in front of it:\n  " <>
               Enum.join(offenders, "\n  ")
    end

    test "money panels report a window total, not a per-second rate" do
      # `rate()` on money answers "dollars per second", which is not a thing an
      # operator reading a spend panel wants. `increase()` over the window is.
      offenders =
        for name <- @dashboards,
            dashboard = load(name),
            dashboard != nil,
            panel <- data_panels(dashboard),
            expr <- exprs(panel),
            String.contains?(expr, "_cents"),
            String.contains?(expr, "rate("),
            do: "#{label(name, panel)}: #{expr}"

      assert offenders == [],
             "money expression(s) use rate(), which renders spend per SECOND — use increase() " <>
               "over the window:\n  " <> Enum.join(offenders, "\n  ")
    end
  end

  describe "panels with several targets" do
    test "a panel whose targets return different kinds carries per-target unit overrides" do
      offenders =
        for name <- @dashboards,
            dashboard = load(name),
            dashboard != nil,
            panel <- data_panels(dashboard),
            kinds = panel |> exprs() |> Enum.map(&target_kind/1) |> Enum.uniq(),
            length(kinds) > 1,
            unit(panel) != "",
            overrides(panel) == [],
            do: "#{label(name, panel)}: kinds #{inspect(kinds)}, unit #{inspect(unit(panel))}"

      assert offenders == [],
             "panel(s) have one `unit` serving targets that return different kinds of thing, so " <>
               "the unit is applied to all of them — this is how a refusal COUNT came to render " <>
               "`$`-prefixed. Add a per-target override (byFrameRefID) rather than splitting the " <>
               "panel, when the series belong side by side:\n  " <> Enum.join(offenders, "\n  ")
    end
  end

  describe "the sweep itself" do
    # ⚠️ Every assertion above is a list-is-empty, which an empty sweep
    # satisfies. The dashboards are read from `priv` at runtime, the panel tree
    # is nested, and `type == "row"` filtering could silently drop everything —
    # so the population is asserted, and the specific panel that motivated all
    # of this is asserted by name.
    test "the sweep reads real panels and finds the money panels it was written for" do
      panels =
        for name <- @dashboards, dashboard = load(name), dashboard != nil do
          {name, data_panels(dashboard)}
        end

      assert panels != [], "no dashboard could be read from priv/grafana"

      total = panels |> Enum.map(fn {_n, p} -> length(p) end) |> Enum.sum()
      assert total > 10, "expected more than ten data panels across the dashboards, got #{total}"

      currency_panels =
        for {name, ps} <- panels,
            panel <- ps,
            unit(panel) == "currencyUSD",
            do: label(name, panel)

      assert length(currency_panels) >= 2,
             "expected at least two currencyUSD panels — the two money panels this gate exists " <>
               "for. Found #{inspect(currency_panels)}; if they were renamed or removed, this " <>
               "sweep is no longer looking at them."

      cents_exprs =
        for {_name, ps} <- panels,
            panel <- ps,
            expr <- exprs(panel),
            String.contains?(expr, "_cents"),
            do: expr

      assert cents_exprs != [],
             "no expression references a _cents family, so the division and rate assertions " <>
               "above are passing over an empty set"
    end
  end
end
