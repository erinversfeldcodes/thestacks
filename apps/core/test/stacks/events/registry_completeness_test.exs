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

  # `event_type: "domain.thing"` — the shape every Stacks.Events.emit/1 call uses.
  @emit_pattern ~r/event_type:\s*"([a-z_]+\.[a-z_]+)"/

  # registry.ex names every type by definition; upcaster.ex's moduledoc uses
  # `"the.type"` as a worked example. Neither is an emitter.
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

    # Guards the guard: if the scanner stops finding emit sites the test above
    # passes vacuously, which is precisely how the original 22-of-54 gap survived.
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
