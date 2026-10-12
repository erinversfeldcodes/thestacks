defmodule Stacks.Events.RegistryCompletenessTest do
  @moduledoc """
      Pins `Registry.all_event_types/0` to what the codebase actually emits.
      The registry once claimed completeness while listing 22 of 54 types —
      an incomplete catalog breaks no caller; replay just quietly does less.

      An emitter is a call to `Stacks.Events.emit/1` or `emit_safe/1`, found by
      walking each module's AST. Grepping for the `event_type:` key instead let
      a CONSUMER stand in for a PRODUCER: a handler's
      `def handle_event(%{event_type: "x"})` head made "x" look emitted, so a
      registered type whose only mention in `lib/` was its own handler passed
      the gate green. Reading the key from the emit call's argument — and only
      from expression position, never a function head — is what makes the
      inverse guard below able to fail.
  """

  use ExUnit.Case, async: true

  alias Stacks.Events.Registry

  @lib_root Path.expand("../../../lib", __DIR__)

  @emit_functions [:emit, :emit_safe]

  # Emit sites whose `event_type` is not a literal in the call's own argument,
  # so the scan cannot read it. Each is declared with the call path that proves
  # the emit is real. Two guards below keep this honest: one fails when a
  # dynamic site appears in a file that is not declared here (or a declared file
  # stops having one), the other when a declared type is not written anywhere in
  # that file. This is a place to record indirection, not a place to park an
  # event nothing emits.
  @indirect_emit_sites %{
    "stacks/books.ex" => %{
      types: ~w(book.created books.confirmed),
      call_path: """
      create/1 and create_confirmed_book/4 call create_work/2 with an `:event`
      builder (&book_created_event/2, &books_confirmed_event/3). The Multi.run
      step emits `opts[:event].(book, edition)`, so the map literal lives in the
      builder rather than in the emit call.
      """
    },
    "stacks/discovery.ex" => %{
      types: ~w(source.approved source.rejected),
      call_path: """
      approve_source/1 and reject_source/1 pass the event type down as an
      argument through transition_source/3 to after_transition/3, which emits
      `event_type: event_type`.
      """
    }
  }

  # --- the scan ------------------------------------------------------------

  defp lib_files, do: @lib_root |> Path.join("**/*.ex") |> Path.wildcard()

  # Collects the single argument of every `…Events.emit/1` and `…Events.emit_safe/1`
  # call. Walking the AST means a function head can never contribute: a call
  # cannot appear in pattern position, so `handle_event(%{event_type: "x"})` and
  # the upcaster's clause heads are structurally excluded rather than excluded by
  # a filename list. Locally-defined `emit/1` helpers (Stacks.AgeVerification,
  # Stacks.AI.VisionError) are excluded too — they carry no `Events.` prefix.
  defp emit_call_args(ast) do
    {_ast, args} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, module}, fun]}, _, [arg]} = node, acc
        when fun in @emit_functions ->
          if List.last(module) == :Events, do: {node, [arg | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(args)
  end

  defp literal_event_type({:%{}, _, pairs}) when is_list(pairs) do
    Enum.find_value(pairs, fn
      {:event_type, type} when is_binary(type) -> type
      _ -> nil
    end)
  end

  defp literal_event_type(_argument), do: nil

  # `nil` marks an emit site whose type the scan could not read.
  defp emit_site_types(source) do
    source
    |> Code.string_to_quoted!()
    |> emit_call_args()
    |> Enum.map(&literal_event_type/1)
  end

  defp emit_sites do
    Enum.flat_map(lib_files(), fn path ->
      relative = Path.relative_to(path, @lib_root)

      path
      |> File.read!()
      |> emit_site_types()
      |> Enum.map(&{&1, relative})
    end)
  end

  defp literal_emit_sites do
    emit_sites()
    |> Enum.reject(fn {event_type, _path} -> is_nil(event_type) end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp dynamic_emit_files do
    emit_sites()
    |> Enum.filter(fn {event_type, _path} -> is_nil(event_type) end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp declared_indirect_sites do
    Enum.flat_map(@indirect_emit_sites, fn {path, %{types: types}} ->
      Enum.map(types, &{&1, path})
    end)
  end

  defp emitted_event_types, do: literal_emit_sites() ++ declared_indirect_sites()

  defp emitted_set, do: MapSet.new(emitted_event_types(), &elem(&1, 0))

  # --- the gate ------------------------------------------------------------

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

    test "every catalogued type is emitted, indirectly emitted, or explicitly pending" do
      emitted = emitted_set()
      pending = Registry.pending_event_types()

      orphans =
        Enum.reject(
          Registry.all_event_types(),
          &(MapSet.member?(emitted, &1) or Map.has_key?(pending, &1))
        )

      assert orphans == [],
             """
             Catalogued event types with no emit site anywhere in apps/core/lib:

             #{Enum.map_join(orphans, "\n", &"  #{&1}")}

             Either the emitter was deleted out from under the wiring — leaving a
             handler that can never run and dbt models nothing refreshes — or the
             type is planned, in which case record it in
             Registry.pending_event_types/0 with the story that keeps it.
             """
    end

    test "pending types really have no emitter — pending is not a place to forget" do
      emitted = emitted_set()

      stale =
        Registry.pending_event_types()
        |> Map.keys()
        |> Enum.filter(&MapSet.member?(emitted, &1))

      assert stale == [],
             "pending event type(s) now have an emitter — remove from Registry @pending: " <>
               inspect(stale)
    end

    test "the emit-site scan finds a realistic number of event types" do
      found = literal_emit_sites()

      assert length(found) >= 55,
             "expected the scan to find 55+ distinct emitted event types, found " <>
               "#{length(found)} — the emit-call walk has probably stopped matching"

      types = Enum.map(found, &elem(&1, 0))
      assert "placement.created" in types
      assert "listing.sold" in types
      assert "image.submitted" in types
    end
  end

  describe "the scan counts producers, not consumers" do
    test "a handler's pattern-match head is not an emit site" do
      source = """
      defmodule Probe.Handler do
        def handle_event(%{event_type: "probe.handled", payload: payload}) do
          {:ok, payload}
        end
      end
      """

      assert emit_site_types(source) == []
    end

    test "an upcaster clause head is not an emit site" do
      source = """
      defmodule Probe.Upcaster do
        def upcast(%{event_type: "probe.upcast", schema_version: 1} = event), do: event
      end
      """

      assert emit_site_types(source) == []
    end

    test "a locally defined emit/1 is not Stacks.Events.emit/1" do
      source = """
      defmodule Probe.Local do
        defp emit(payload), do: {:error, payload}
        def go, do: emit(%{event_type: "probe.local"})
      end
      """

      assert emit_site_types(source) == []
    end

    test "an emit call is an emit site whatever the key order" do
      source = """
      defmodule Probe.Emitter do
        def go(id) do
          Events.emit_safe(%{
            aggregate_id: id,
            aggregate_type: "probe",
            event_type: "probe.emitted"
          })
        end
      end
      """

      assert emit_site_types(source) == ["probe.emitted"]
    end

    test "a fully qualified emit call is an emit site" do
      source = """
      defmodule Probe.Qualified do
        def go(id), do: Stacks.Events.emit(%{event_type: "probe.qualified", aggregate_id: id})
      end
      """

      assert emit_site_types(source) == ["probe.qualified"]
    end

    test "an emit call the scan cannot read is reported, not silently dropped" do
      source = """
      defmodule Probe.Dynamic do
        def go(event_type, id) do
          Events.emit_safe(%{event_type: event_type, aggregate_id: id})
        end
      end
      """

      assert emit_site_types(source) == [nil],
             "an emit call whose type the scan cannot read must surface as an unreadable " <>
               "site (nil) so the declaration guard sees it, not vanish from the scan"
    end
  end

  describe "indirect emit sites" do
    test "every emit site the scan cannot read is declared" do
      assert dynamic_emit_files() == Enum.sort(Map.keys(@indirect_emit_sites)),
             """
             The set of files holding an emit call whose event_type the scan cannot
             read has drifted from @indirect_emit_sites.

               found in lib:  #{inspect(dynamic_emit_files())}
               declared:      #{inspect(Enum.sort(Map.keys(@indirect_emit_sites)))}

             A new one means an emitter this gate cannot see: declare it with the
             types it produces and the call path that proves the emit. One that has
             gone means the indirection was removed — drop the declaration so the
             types are checked directly again.
             """
    end

    test "every declared indirect type is written in the file that declares it" do
      missing =
        Enum.flat_map(@indirect_emit_sites, fn {path, %{types: types}} ->
          source = File.read!(Path.join(@lib_root, path))
          types |> Enum.reject(&String.contains?(source, ~s("#{&1}"))) |> Enum.map(&{&1, path})
        end)

      assert missing == [],
             "declared indirect event type(s) no longer appear in their file: " <>
               inspect(missing)
    end

    test "no module renames the Events alias out from under the scan" do
      renamed =
        lib_files()
        |> Enum.filter(&(File.read!(&1) =~ ~r/alias\s+Stacks\.Events\s*,\s*as:/))
        |> Enum.map(&Path.relative_to(&1, @lib_root))

      assert renamed == [],
             "the emit-call walk matches on the alias tail `Events`; these modules " <>
               "rename it and would be invisible to it: #{inspect(renamed)}"
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
