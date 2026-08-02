defmodule Core.PromEx.VisionLatencyTest do
  @moduledoc """
  Issue #349 — `Stacks.AI.Client` has always measured how long a Modal vision
  call takes and emitted it on `[:stacks, :vision, :request, :stop]`, and until
  this metric existed **nothing consumed it**: the duration never left the BEAM,
  so every timeout in the upload path was sized from an estimate in a comment.

  This suite proves the two things a compiling metric definition does NOT prove:

    1. **It is attached.** A `Telemetry.Metrics` struct in a plugin is inert
       until PromEx registers a handler for its `event_name`. The export
       assertions below emit the REAL event and read it back out of
       `PromEx.get_metrics/1` — the same path `/internal/metrics` and the
       ADR-021 push both read. (What they still cannot prove is that the push
       reaches VictoriaMetrics; that needs a real upload against a deployed
       stack, and is the lead's merge-time check. The #248 lesson is that this
       stack once shipped structurally complete and blank.)

    2. **Its buckets span the claim it tests.** A histogram whose ceiling sits
       below the real tail reports a p95 that is an artefact of the ceiling —
       the 2026-04-20 incident recorded in `Core.PromEx.Plugins.Stacks`. The
       bucket assertions tie the top bucket to
       `Stacks.AI.Client.receive_timeout_ms/0` (so #350's retune of that
       timeout cannot silently leave the histogram short) and put edges on the
       "~3–8s" estimate this metric exists to check.

  `async: false` — PromEx state is global and these assertions read scraped
  output. Series are isolated from other suites (`observability_telemetry_test`
  emits the same event) by using `status` values no other test emits.
  """

  # async: false — PromEx aggregator state is global.
  use ExUnit.Case, async: false

  alias Core.PromEx.MetricAudience
  alias Core.PromEx.Plugins.Stacks, as: StacksPlugin
  alias Stacks.AI.Client, as: VisionClient

  @family "stacks_vision_request_stop_duration_milliseconds"
  @event [:stacks, :vision, :request, :stop]

  # `status` values used ONLY here, so a series matched below cannot have been
  # produced by another suite emitting the same event name.
  @slow_status 599
  @error_status 502

  defp metric! do
    StacksPlugin.event_metrics([])
    |> Enum.flat_map(& &1.metrics)
    |> Enum.find(&(Enum.join(&1.name, "_") == @family))
    |> case do
      nil ->
        flunk(
          "no metric registered under #{@family}; registered: " <>
            inspect(
              StacksPlugin.event_metrics([])
              |> Enum.flat_map(& &1.metrics)
              |> Enum.map(&Enum.join(&1.name, "_"))
            )
        )

      metric ->
        metric
    end
  end

  defp buckets, do: metric!().reporter_options[:buckets]

  defp emit(duration_ms, endpoint, status) do
    :telemetry.execute(
      @event,
      %{duration: System.convert_time_unit(duration_ms, :millisecond, :native)},
      %{endpoint: endpoint, status: status}
    )
  end

  defp scrape do
    # Give PromEx's telemetry handler a moment to process the ETS writes.
    Process.sleep(50)
    output = PromEx.get_metrics(Core.PromEx)
    refute output == :prom_ex_down, "Core.PromEx must be running for this test"
    output
  end

  # Every exported line of `<family><suffix>` whose label block matches all of
  # `pairs`, as {label_block, value} tuples.
  defp series(output, suffix, pairs) do
    for line <- String.split(output, "\n"),
        [_, block, value] <-
          Regex.scan(~r/^#{Regex.escape(@family <> suffix)}\{([^}]*)\}\s+(\S+)$/, line),
        Enum.all?(pairs, fn {k, v} -> String.contains?(block, ~s(#{k}="#{v}")) end) do
      {block, value}
    end
  end

  defp label_keys(block) do
    ~r/([a-zA-Z_][a-zA-Z0-9_]*)="/
    |> Regex.scan(block)
    |> Enum.map(fn [_, key] -> key end)
    |> MapSet.new()
  end

  # The only label keys this family may ever export: the two whitelisted tags
  # plus the histogram's own bucket bound.
  defp whitelist, do: MapSet.new(["endpoint", "status", "le"])

  describe "the metric is registered at all (the defect this issue is)" do
    test "a distribution over the vision stop event exists, keyed by endpoint and status" do
      metric = metric!()

      assert %Telemetry.Metrics.Distribution{} = metric,
             "expected #{@family} to be a distribution (a counter cannot answer p95), got: " <>
               inspect(metric.__struct__)

      assert metric.event_name == @event
      assert metric.tags == [:endpoint, :status]

      # `unit: {:native, :millisecond}` makes Telemetry.Metrics replace the
      # `:duration` measurement key with a converting function, so assert the
      # conversion itself: the client measures with System.monotonic_time/0
      # (native units), and without the conversion every exported value would
      # be nanoseconds and every quantile off by six orders of magnitude.
      assert metric.unit == :millisecond
      assert is_function(metric.measurement, 1)

      native_8s = System.convert_time_unit(8_000, :millisecond, :native)

      assert_in_delta metric.measurement.(%{duration: native_8s}), 8_000, 1
    end

    test "the family is classified :public, so it is allowed onto a dashboard" do
      assert MetricAudience.audience(@family) == :public
    end
  end

  describe "buckets span the claim being tested (Issue #349 requirement 2)" do
    test "the top finite bucket is the client's own give-up deadline" do
      ceiling = VisionClient.receive_timeout_ms()

      assert Enum.max(buckets()) == ceiling,
             "the top finite bucket must equal Stacks.AI.Client.receive_timeout_ms() " <>
               "(#{ceiling}ms). A :stop event can never carry a longer duration — a slower " <>
               "call exits via the :exception path — so a ceiling AT the deadline makes +Inf " <>
               "structurally unreachable and no quantile can be the '2 × max_finite_bucket' " <>
               "fallback. Buckets: #{inspect(buckets())}. If the timeout moved (Issue #350), " <>
               "move the top bucket with it."
    end

    test "3s and 8s are bucket EDGES, so the '~3-8s' estimate is readable without interpolation" do
      for edge <- [3_000, 8_000] do
        assert edge in buckets(),
               "expected #{edge}ms to be a bucket edge so the share of calls inside the " <>
                 "documented ~3-8s cost estimate falls straight out of two bucket counts; " <>
                 "buckets: #{inspect(buckets())}"
      end
    end

    test "buckets are strictly ascending and give sub-second resolution below the estimate" do
      assert buckets() == Enum.sort(buckets())
      assert buckets() == Enum.uniq(buckets())

      below_estimate = Enum.filter(buckets(), &(&1 < 3_000))

      assert length(below_estimate) >= 4,
             "a call faster than the estimate must not collapse into one bucket, or p50 is a " <>
               "smear; buckets below 3000ms: #{inspect(below_estimate)}"
    end
  end

  describe "the metric is ATTACHED, not merely defined (emit → PromEx export)" do
    test "emitting the real event exports the bucket/sum/count triple with both labels" do
      emit(1_500, "analyze", @error_status)

      output = scrape()

      assert output =~ "#{@family}_bucket",
             "expected #{@family}_bucket in PromEx output — the metric is defined but no " <>
               "handler is attached to #{inspect(@event)}, got:\n#{output}"

      for suffix <- ["_bucket", "_sum", "_count"] do
        found = series(output, suffix, endpoint: "analyze", status: @error_status)

        assert found != [],
               "expected a #{@family}#{suffix} series labelled endpoint=\"analyze\" " <>
                 "status=\"#{@error_status}\" (the non-200 path emits too), got:\n#{output}"
      end
    end

    test "a slow call lands in a FINITE bucket, not only +Inf (anti-saturation)" do
      # 60s: far beyond the ~3-8s estimate, far short of the client's deadline.
      # With a 20_000ms ceiling (the @route_duration_buckets shape this issue
      # warns against) this sample would exist ONLY in +Inf and the quantile
      # would be a fabricated fallback.
      emit(60_000, "analyze", @slow_status)

      output = scrape()

      pairs = [endpoint: "analyze", status: @slow_status]

      assert [{_, "0"} | _] = series(output, "_bucket", pairs ++ [le: 30_000]),
             "a 60s sample must NOT be counted in the le=30000 bucket; got:\n#{output}"

      assert [{_, count} | _] = series(output, "_bucket", pairs ++ [le: 120_000])

      assert String.to_integer(count) >= 1,
             "a 60s sample must land in the finite le=120000 bucket — if it only appears in " <>
               "+Inf the ceiling is too low and the tail this metric exists to measure is " <>
               "invisible; got:\n#{output}"

      # Read the ceiling rather than restating it. Issue #350 moved the client's
      # deadline (210s → 330s) and this literal was the one place that did not
      # move with it, which is the same "two copies of a number that must agree"
      # trap that produced the inversion #350 fixed.
      assert [{_, top} | _] = series(output, "_bucket", pairs ++ [le: Enum.max(buckets())])

      assert String.to_integer(top) >= 1,
             "cumulative buckets: the top finite bucket must also include the 60s sample"
    end
  end

  describe "no non-whitelisted metadata reaches a label (GDPR: telemetry is warehouse-adjacent)" do
    test "the exported label set is exactly endpoint, status and the histogram's le" do
      emit(2_000, "extract_isbn", @error_status)

      output = scrape()

      blocks =
        output
        |> series("_bucket", endpoint: "extract_isbn", status: @error_status)
        |> Enum.map(fn {block, _} -> block end)

      assert blocks != [], "expected an exported series to inspect, got:\n#{output}"

      for block <- blocks do
        assert MapSet.equal?(label_keys(block), whitelist()),
               "unexpected label key on #{@family} — only the bounded endpoint/status pair " <>
                 "(plus the histogram's le) may reach the metrics sink; no ISBN, title, " <>
                 "filename, image id or user id: #{block}"
      end
    end

    test "metadata outside the whitelist is DROPPED, not exported, if an emit site adds it" do
      # The guarantee is the `:tags` whitelist, not the discipline of every
      # future emit site. Emit the event carrying exactly the kind of payload
      # that must never reach a metrics sink and prove none of it becomes a
      # label. This is what makes the whitelist a guarantee rather than a
      # convention.
      :telemetry.execute(
        @event,
        %{duration: System.convert_time_unit(900, :millisecond, :native)},
        %{
          endpoint: "is_book",
          status: @error_status,
          isbn: "9780241543382",
          title: "The Hobbit",
          user_id: "11111111-1111-1111-1111-111111111111",
          image_url: "https://example.test/upload.jpg"
        }
      )

      output = scrape()

      leaked =
        output
        |> series("_bucket", endpoint: "is_book", status: @error_status)
        |> Enum.flat_map(fn {block, _} ->
          MapSet.to_list(MapSet.difference(label_keys(block), whitelist()))
        end)
        |> Enum.uniq()

      assert leaked == [],
             "these metadata keys became metric LABELS: #{inspect(leaked)} — the :tags " <>
               "whitelist on #{@family} is the only thing keeping upload content out of the " <>
               "metrics sink"

      refute output =~ "9780241543382"
      refute output =~ "The Hobbit"
      refute output =~ "example.test"
    end
  end
end
