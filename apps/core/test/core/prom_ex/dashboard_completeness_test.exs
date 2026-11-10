defmodule Core.PromEx.DashboardCompletenessTest do
  @moduledoc """
      Global "measured ⊆ displayed" gate: the per-dashboard drift
      tests prove displayed ⊆ measured; this is the REVERSE across ALL
      dashboards in `Core.PromEx.dashboards/0` — every registered `stacks_*`
      family classified `:public` in `MetricAudience` must have a panel
      somewhere. Measured-but-invisible is the failure mode this gate exists
      to kill; `:own`/`:break_glass` families are exempt.
  """
  use ExUnit.Case, async: true

  alias Core.PromEx.ExternalFamilies
  alias Core.PromEx.MetricAudience
  alias Core.PromEx.Plugins.Stacks, as: StacksPlugin

  # ⛔ "MEASURED" MEANT "REGISTERED BY THIS APP", so this gate passed vacuously
  # over every series pushed from outside it — and the families it could not
  # see were the billing ones, the only figures in the system that come from a
  # provider's invoice rather than our own arithmetic. `measured ⊆ displayed`
  # held over a set that never contained them, which is the shape that let the
  # whole metrics pipeline ship blank once before: a green gate whose inputs
  # exclude the thing that is broken.
  #
  # ⚖️ Externally-pushed families are now part of the universe, so they must
  # have panels like anything else. Declared in `Core.PromEx.ExternalFamilies`
  # rather than matched by prefix, because the requirement is enumerable or it
  # is nothing.
  defp registered_families do
    plugin =
      StacksPlugin.event_metrics([])
      |> Enum.flat_map(& &1.metrics)
      |> Enum.map(&Enum.join(&1.name, "_"))

    Enum.uniq(plugin ++ ExternalFamilies.families())
  end

  defp all_panels(%{"panels" => panels}) when is_list(panels),
    do: Enum.flat_map(panels, &[&1 | all_panels(&1)])

  defp all_panels(_), do: []

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
