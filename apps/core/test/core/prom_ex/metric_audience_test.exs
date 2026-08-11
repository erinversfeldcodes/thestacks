defmodule Core.PromEx.MetricAudienceTest do
  @moduledoc """
    Enforces the ADR-021 §4 audience gate: every registered `stacks_*` family is
    consciously classified (measured ⊆ classified), the default is fail-closed
    (a new/unknown metric is NOT public until promoted), and there are no stale
    entries. Derives the registered family list from the plugin the same way as
    `DashboardDriftTest` / `DashboardLabelValidationTest` — never hard-coded.
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

  test "every registered family is consciously classified (adding a metric without a classification fails the build)" do
    unclassified =
      for family <- registered_families(),
          MetricAudience.audience(family) == :unclassified,
          do: family

    assert unclassified == [],
           "these registered metrics have no audience — classify each :public/:own/:break_glass " <>
             "in Core.PromEx.MetricAudience (absent == invisible on every dashboard): " <>
             inspect(unclassified)
  end

  test "fail-closed: an unknown/future metric is NOT public until explicitly promoted" do
    future = "stacks_future_blog_engagement_count_total"
    refute MetricAudience.public?(future)
    assert MetricAudience.audience(future) == :unclassified
  end

  test "all current families are:public (aggregate + non-PII per the audit)" do
    non_public =
      for family <- registered_families(),
          MetricAudience.audience(family) != :public,
          do: family

    assert non_public == [],
           "expected every current family to be :public; these are not: " <> inspect(non_public)
  end

  test "no stale entries — every classified family is still registered" do
    registered = MapSet.new(registered_families())

    stale =
      for {family, _audience} <- MetricAudience.all(),
          not MapSet.member?(registered, family),
          do: family

    assert stale == [],
           "MetricAudience classifies families that are no longer registered: " <> inspect(stale)
  end

  test "public_families/0 returns exactly the :public-classified set" do
    assert MapSet.new(MetricAudience.public_families()) ==
             MapSet.new(for {f, :public} <- MetricAudience.all(), do: f)
  end

  test "every metric on the public transparency allowlist is classified :public (no leak to the public page)" do
    families =
      Stacks.Transparency.allowlist_queries()
      |> Enum.flat_map(&Regex.scan(~r/stacks_[a-zA-Z0-9_]+/, &1))
      |> List.flatten()
      |> Enum.map(&normalize_family/1)
      |> Enum.uniq()

    assert families != [], "expected the allowlist to reference some stacks_* metrics"

    non_public = Enum.reject(families, &MetricAudience.public?/1)

    assert non_public == [],
           "the public transparency allowlist references non-:public metrics — these would leak " <>
             "to the public /metrics page: " <> inspect(non_public)
  end

  defp normalize_family(name) do
    cond do
      String.ends_with?(name, "_bucket") -> String.replace_suffix(name, "_bucket", "")
      String.ends_with?(name, "_sum") -> String.replace_suffix(name, "_sum", "")
      String.ends_with?(name, "_count") -> String.replace_suffix(name, "_count", "")
      true -> name
    end
  end
end
