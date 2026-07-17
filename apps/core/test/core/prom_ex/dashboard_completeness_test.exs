defmodule Core.PromEx.DashboardCompletenessTest do
  @moduledoc """
  Global "measured ⊆ displayed" gate (ADR-021 / Epic #249 #256).

  The per-dashboard drift tests prove each dashboard's panels reference only
  *registered* metrics (displayed ⊆ measured). This is the REVERSE, across ALL
  dashboards registered in `Core.PromEx.dashboards/0`: every registered
  `stacks_*` family classified `:public` in `Core.PromEx.MetricAudience` MUST
  have a panel somewhere — a public metric with no panel is measured-but-invisible,
  which is the whole failure mode this epic exists to kill. `:own`/`:break_glass`
  families are exempt (they never go on the public dashboards); `:unclassified` is
  already a hard failure in `MetricAudienceTest`.

  Registered family names come from the plugin the same way as `DashboardDriftTest`
  (`metric.name |> Enum.join("_")`); panel selectors are normalised back to that
  family (histogram `_bucket`/`_sum`/`_count` stripped) before comparison.
  """
  use ExUnit.Case, async: true

  alias Core.PromEx.MetricAudience
  alias Core.PromEx.Plugins.Stacks, as: StacksPlugin

  defp registered_families do
    StacksPlugin.event_metrics([])
    |> Enum.flat_map(& &1.metrics)
    |> Enum.map(&Enum.join(&1.name, "_"))
    |> Enum.uniq()
  end

  defp all_panels(%{"panels" => panels}) when is_list(panels),
    do: Enum.flat_map(panels, &[&1 | all_panels(&1)])

  defp all_panels(_), do: []

  # Every family referenced by any panel across ALL registered dashboards,
  # normalised to the registered family key.
  defp displayed_families do
    for {:core, rel} <- Core.PromEx.dashboards(),
        path = Application.app_dir(:core, Path.join("priv", rel)),
        File.exists?(path),
        dashboard = path |> File.read!() |> Jason.decode!(),
        panel <- all_panels(dashboard),
        panel["type"] != "row",
        target <- panel["targets"] || [],
        expr = target["expr"],
        is_binary(expr),
        match <- Regex.scan(~r/stacks_[a-zA-Z0-9_]+/, expr),
        name <- match,
        into: MapSet.new() do
      normalize_family(name)
    end
  end

  defp normalize_family(name) do
    cond do
      String.ends_with?(name, "_bucket") -> String.replace_suffix(name, "_bucket", "")
      String.ends_with?(name, "_sum") -> String.replace_suffix(name, "_sum", "")
      String.ends_with?(name, "_count") -> String.replace_suffix(name, "_count", "")
      true -> name
    end
  end

  test "every :public registered metric family has a dashboard panel (measured ⊆ displayed)" do
    displayed = displayed_families()
    assert MapSet.size(displayed) > 0, "expected the dashboards to reference some metrics"

    missing =
      registered_families()
      |> Enum.filter(&(MetricAudience.audience(&1) == :public))
      |> Enum.reject(&MapSet.member?(displayed, &1))

    assert missing == [],
           "these :public metrics have NO dashboard panel (measured but invisible) — add a panel " <>
             "or reclassify in Core.PromEx.MetricAudience: " <> inspect(missing)
  end

  test "no dashboard panel references a family that is not registered (displayed ⊆ measured, global)" do
    registered = MapSet.new(registered_families())

    unknown =
      displayed_families()
      |> Enum.reject(&MapSet.member?(registered, &1))

    assert unknown == [],
           "dashboard panels reference metric families not registered by the plugin " <>
             "(renamed/removed?): " <> inspect(unknown)
  end
end
