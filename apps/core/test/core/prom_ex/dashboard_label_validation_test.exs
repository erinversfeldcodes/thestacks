defmodule Core.PromEx.DashboardLabelValidationTest do
  @moduledoc """
    Offline LABEL-key drift guard for the ops dashboards: the
    drift tests validate metric NAMES, but a typo'd label key
    (`{outcom="x"}`, `by (sourc)`) is name-correct and still renders a
    permanently-empty panel — Prometheus silently matches no series. Parses
    every panel's PromQL selectors/groupings and asserts each label key is
    one the metric actually carries (from the plugin's tag definitions).
  """

  use ExUnit.Case, async: true

  alias Core.PromEx.Plugins.Stacks, as: StacksPlugin

  @selector_regex ~r/(stacks_[a-zA-Z0-9_]+)\{([^}]*)\}/

  @matcher_key_regex ~r/([a-zA-Z_][a-zA-Z0-9_]*)\s*(?:=~|!~|!=|=)\s*"/

  @grouping_regex ~r/\b(?:by|without)\s*\(([^)]*)\)/

  @distribution_suffixes ["_bucket", "_sum", "_count"]

  @app_key "app"
  @le_key "le"

  defp allowed_by_family do
    StacksPlugin.event_metrics([])
    |> Enum.flat_map(& &1.metrics)
    |> Map.new(fn metric ->
      family = metric.name |> Enum.join("_")
      tags = MapSet.new(metric.tags, &Atom.to_string/1)

      allowed =
        if distribution?(metric), do: MapSet.put(tags, @le_key), else: tags

      {family, allowed}
    end)
  end

  defp distribution?(%Telemetry.Metrics.Distribution{}), do: true
  defp distribution?(_), do: false

  defp normalize_family(name, allowed) do
    if Map.has_key?(allowed, name),
      do: name,
      else: Enum.find_value(@distribution_suffixes, &stripped_family(name, &1, allowed))
  end

  defp stripped_family(name, suffix, allowed) do
    base = String.replace_suffix(name, suffix, "")
    if base != name and Map.has_key?(allowed, base), do: base
  end

  defp registered_dashboard_paths do
    Enum.map(Core.PromEx.dashboards(), fn
      {:core, relative} -> relative
      other -> flunk("unexpected dashboards/0 entry (expected {:core, path}): #{inspect(other)}")
    end)
  end

  defp dashboard_path(relative),
    do: Application.app_dir(:core, Path.join("priv", relative))

  defp all_panels(%{"panels" => panels}) when is_list(panels) do
    Enum.flat_map(panels, fn panel -> [panel | all_panels(panel)] end)
  end

  defp all_panels(_), do: []

  defp data_panels(dashboard) do
    dashboard
    |> all_panels()
    |> Enum.reject(&(&1["type"] == "row"))
  end

  def expr_violations(expr, allowed) when is_binary(expr) do
    inline_matcher_violations(expr, allowed) ++ grouping_violations(expr, allowed)
  end

  defp inline_matcher_violations(expr, allowed) do
    for [_, raw_name, block] <- Regex.scan(@selector_regex, expr),
        family = normalize_family(raw_name, allowed),
        not is_nil(family),
        [_, key] <- Regex.scan(@matcher_key_regex, block),
        not key_allowed?(key, family, allowed) do
      %{kind: :matcher, family: family, key: key, allowed: allowed_keys(family, allowed)}
    end
  end

  defp grouping_violations(expr, allowed) do
    families =
      for [_, raw_name] <- Regex.scan(~r/(stacks_[a-zA-Z0-9_]+)/, expr),
          family = normalize_family(raw_name, allowed),
          not is_nil(family),
          uniq: true,
          do: family

    case families do
      [family] ->
        for [_, clause] <- Regex.scan(@grouping_regex, expr),
            key <- split_grouping_keys(clause),
            not key_allowed?(key, family, allowed) do
          %{kind: :grouping, family: family, key: key, allowed: allowed_keys(family, allowed)}
        end

      _ambiguous_or_none ->
        []
    end
  end

  defp split_grouping_keys(clause) do
    clause
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp key_allowed?(@app_key, _family, _allowed), do: true
  defp key_allowed?(key, family, allowed), do: MapSet.member?(allowed_keys(family, allowed), key)

  defp allowed_keys(family, allowed), do: Map.get(allowed, family, MapSet.new())

  describe "registered family label-key derivation" do
    test "families expose their declared tags, and distributions additionally allow le" do
      allowed = allowed_by_family()

      assert MapSet.equal?(
               Map.fetch!(allowed, "stacks_upload_terminal_count_total"),
               MapSet.new(["outcome"])
             )

      assert MapSet.equal?(
               Map.fetch!(allowed, "stacks_router_dispatch_stop_duration_milliseconds"),
               MapSet.new(["route_group", "le"])
             )

      assert normalize_family(
               "stacks_router_dispatch_stop_duration_milliseconds_bucket",
               allowed
             ) == "stacks_router_dispatch_stop_duration_milliseconds"

      assert normalize_family("stacks_not_a_real_family", allowed) == nil
    end
  end

  describe "every panel's label keys are keys the metric actually exports" do
    test "no data panel filters or groups on a label key the family never carries" do
      allowed = allowed_by_family()

      violations =
        for relative <- registered_dashboard_paths(),
            dashboard = relative |> dashboard_path() |> File.read!() |> Jason.decode!(),
            panel <- data_panels(dashboard),
            target <- panel["targets"] || [],
            expr = target["expr"],
            is_binary(expr),
            violation <- expr_violations(expr, allowed) do
          Map.merge(violation, %{
            dashboard: relative,
            panel: panel["title"] || panel["id"],
            expr: expr
          })
        end

      assert violations == [],
             "these panels reference label keys their metric family never exports " <>
               "(typo'd matcher/grouping key → permanently-empty Grafana panel):\n" <>
               Enum.map_join(violations, "\n", fn v ->
                 "  • [#{v.dashboard}] panel #{inspect(v.panel)}: #{v.kind} key " <>
                   "#{inspect(v.key)} not a label of #{v.family} " <>
                   "(allowed: app, #{Enum.join(Enum.sort(MapSet.to_list(v.allowed)), ", ")})\n" <>
                   "    expr: #{v.expr}"
               end)
    end
  end

  describe "the validator actually rejects a bad label key (proof it catches the bug)" do
    setup do
      %{allowed: allowed_by_family()}
    end

    test "a correct app-scoped expr produces no violations", %{allowed: allowed} do
      good =
        ~s|sum by (outcome) (rate(stacks_upload_terminal_count_total{app="$app",outcome="resolved"}[$__rate_interval]))|

      assert expr_violations(good, allowed) == []
    end

    test "a typo'd inline matcher KEY is rejected and named", %{allowed: allowed} do
      bad =
        ~s|sum by (outcome) (rate(stacks_upload_terminal_count_total{app="$app",outcom="resolved"}[$__rate_interval]))|

      violations = expr_violations(bad, allowed)

      assert Enum.any?(violations, fn v ->
               v.kind == :matcher and v.key == "outcom" and
                 v.family == "stacks_upload_terminal_count_total"
             end),
             "expected the typo'd inline matcher key `outcom` to be rejected, got: " <>
               inspect(violations)
    end

    test "a typo'd `by (...)` grouping KEY is rejected and named", %{allowed: allowed} do
      bad =
        ~s|sum by (sourc) (rate(stacks_upload_terminal_count_total{app="$app"}[$__rate_interval]))|

      violations = expr_violations(bad, allowed)

      assert Enum.any?(violations, fn v ->
               v.kind == :grouping and v.key == "sourc" and
                 v.family == "stacks_upload_terminal_count_total"
             end),
             "expected the typo'd grouping key `sourc` to be rejected, got: " <>
               inspect(violations)
    end

    test "le is accepted on a histogram _bucket selector but not invented tags", %{
      allowed: allowed
    } do
      good =
        ~s|histogram_quantile(0.95, sum by (le, route_group) (rate(stacks_router_dispatch_stop_duration_milliseconds_bucket{app="$app"}[$__rate_interval])))|

      assert expr_violations(good, allowed) == []

      bad =
        ~s|histogram_quantile(0.95, sum by (le, route_grp) (rate(stacks_router_dispatch_stop_duration_milliseconds_bucket{app="$app"}[$__rate_interval])))|

      assert Enum.any?(expr_violations(bad, allowed), &(&1.key == "route_grp"))
    end
  end
end
