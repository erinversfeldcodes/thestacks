defmodule Stacks.Events.RegistryCompletenessTest do
  @moduledoc """
  Pins `Stacks.Events.Registry.all_event_types/0` to what the codebase actually emits.

  The registry's moduledoc claimed to be "the complete catalog … surfaced by
  `all_event_types/0` for replay/diagnostics" while listing 22 of the 54 emitted
  types. Nothing caught that, because a catalog that is merely *incomplete* breaks
  no caller — replay tooling just quietly does less than you think it does.

  This test reads the source of `apps/core/lib` for `event_type: "..."` emit sites
  and asserts every one of them is catalogued. It is a grep, and grepping source is
  ordinarily a poor substitute for a behavioural test — but here the property under
  test *is* a property of the source: "every event type this codebase can emit is
  named in one of two lists". There is no runtime moment at which all emitters have
  run, so there is nothing else to observe.
  """

  use ExUnit.Case, async: true

  alias Stacks.Events.Registry

  @lib_root Path.expand("../../../lib", __DIR__)

  @emit_pattern ~r/event_type:\s*"([a-z_]+\.[a-z_]+)"/

  @non_emitting_files ~w(registry.ex upcaster.ex)

  defp emitted_event_types do
    @lib_root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) in @non_emitting_files))
    |> Enum.flat_map(fn path ->
      @emit_pattern
      |> Regex.scan(File.read!(path), capture: :all_but_first)
      |> Enum.map(fn [event_type] -> {event_type, Path.relative_to(path, @lib_root)} end)
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  describe "all_event_types/0 completeness" do
    test "catalogues every event type emitted anywhere in apps/core/lib" do
      catalogued = MapSet.new(Registry.all_event_types())

      uncatalogued =
        emitted_event_types()
        |> Enum.reject(fn {event_type, _path} -> MapSet.member?(catalogued, event_type) end)
        |> Enum.sort()

      assert uncatalogued == [],
             """
             Event types are emitted but missing from Stacks.Events.Registry:

             #{Enum.map_join(uncatalogued, "\n", fn {t, p} -> "  #{t}  (#{p})" end)}

             Add each to @registry (with its handlers) or to @unsubscribed (with why
             nothing listens). all_event_types/0 is what replay and diagnostics use;
             an omission there is a gap in the vocabulary, not a cosmetic one.
             """
    end

    @indirectly_emitted %{}

    test "every catalogued type is emitted, indirectly emitted, or explicitly pending" do
      emitted = MapSet.new(emitted_event_types(), &elem(&1, 0))
      pending = Registry.pending_event_types()

      orphans =
        Enum.reject(
          Registry.all_event_types(),
          &(MapSet.member?(emitted, &1) or Map.has_key?(pending, &1) or
              Map.has_key?(@indirectly_emitted, &1))
        )

      assert orphans == [],
             """
             Catalogued event types with no emit site anywhere in apps/core/lib:

             #{Enum.map_join(orphans, "\n", &"  #{&1}")}

             Either the emitter was deleted out from under the wiring (the #336
             defect: a handler that can never run, dbt models nothing refreshes),
             or the type is planned — in which case record it in
             Registry.pending_event_types/0 with the story that keeps it.
             """
    end

    test "pending types really have no emitter — pending is not a place to forget" do
      emitted = MapSet.new(emitted_event_types(), &elem(&1, 0))

      stale =
        Registry.pending_event_types()
        |> Map.keys()
        |> Enum.filter(&MapSet.member?(emitted, &1))

      assert stale == [],
             "pending event type(s) now have an emitter — remove from Registry @pending: " <>
               inspect(stale)
    end

    test "the emit-site scan finds a realistic number of event types" do
      found = emitted_event_types()

      assert length(found) >= 50,
             "expected the scan to find 50+ emit sites, found #{length(found)} — " <>
               "the emit pattern has probably stopped matching"

      types = Enum.map(found, &elem(&1, 0))
      assert "placement.created" in types
      assert "listing.sold" in types
      assert "image.submitted" in types
    end
  end

  describe "the two lists" do
    test "are disjoint" do
      subscribed = Registry.all_event_types() -- Registry.unsubscribed_event_types()
      overlap = Enum.filter(Registry.unsubscribed_event_types(), &(&1 in subscribed))

      assert overlap == []
    end

    test "unsubscribed types really have no handlers" do
      for event_type <- Registry.unsubscribed_event_types() do
        assert Registry.handlers_for(event_type) == [],
               "#{event_type} is listed as unsubscribed but has handlers"
      end
    end

    test "every unsubscribed type is in the catalog" do
      catalogued = MapSet.new(Registry.all_event_types())

      for event_type <- Registry.unsubscribed_event_types() do
        assert MapSet.member?(catalogued, event_type)
      end
    end
  end
end
