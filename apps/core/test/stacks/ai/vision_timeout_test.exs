defmodule Stacks.AI.VisionTimeoutTest do
  @moduledoc """
    350 — the vision client gave up 90s BEFORE Modal's own 300s deadline,
    so core hung up on calls the GPU was still (billably) working on, then
    retried into the same contention. Proves the client ceiling is DERIVED
    as the server deadline + slack (never below it), that the derivation
    reads the sidecar's constant, and that the timeout branch classifies
    `:transient`.
  """

  use ExUnit.Case, async: false

  alias Core.PromEx.MetricAudience
  alias Core.PromEx.Plugins.Stacks, as: StacksPlugin
  alias Stacks.AI.Client, as: VisionClient

  @modal_app_path Path.expand("../../../../vision/modal_app.py", __DIR__)
  @family "stacks_vision_request_exception_count_total"
  @event [:stacks, :vision, :request, :exception]

  @isolating_endpoint "vision_timeout_test"

  describe "the client outlasts the service (the inversion this issue is)" do
    test "the receive timeout is at least Modal's own function timeout" do
      client = VisionClient.receive_timeout_ms()
      modal = VisionClient.modal_function_timeout_ms()

      assert client >= modal,
             "the vision client gives up after #{client}ms but Modal allows its function " <>
               "#{modal}ms. Hanging up first does not save the GPU work — it abandons a call " <>
               "that is still running and still billing, then retries it (the transport " <>
               "timeout is :transient), queueing another cold start behind the same contended " <>
               "GPU. If cost is the concern the lever is Modal's timeout and concurrency, " <>
               "never the client's patience."
    end

    test "the ordering is derived, not a coincidence of two literals" do
      client = VisionClient.receive_timeout_ms()
      modal = VisionClient.modal_function_timeout_ms()

      slack = client - modal

      assert slack > 0,
             "the client must allow strictly more than Modal's own deadline: once Modal's " <>
               "function times out the platform still has to serialise an error and return it " <>
               "through its proxy. Equal deadlines make the losing side a race."

      assert slack >= 10_000,
             "#{slack}ms of slack over Modal's deadline is too thin to survive a slow error " <>
               "response; the derivation in Stacks.AI.Client uses 30s."
    end
  end

  describe "the Elixir mirror of Modal's timeout is checked against the Python" do
    test "modal_app.py is where the timeout lives and is readable from here" do
      assert File.exists?(@modal_app_path),
             "expected the vision service source at #{@modal_app_path}. The Elixir constant " <>
               "claims to mirror a value in it; if the file cannot be read, the claim is " <>
               "unverifiable and this test is the only thing that would have said so."
    end

    test "exactly one function timeout is declared, so the mirror is unambiguous" do
      matches = Regex.scan(~r/^\s*timeout=(\d+),?\s*$/m, File.read!(@modal_app_path))

      assert length(matches) == 1,
             "expected exactly one `timeout=` declaration in modal_app.py; found " <>
               "#{length(matches)}: #{inspect(matches)}. With more than one, the Elixir mirror " <>
               "is ambiguous about which deadline it reflects — name the one core waits on."
    end

    test "@modal_function_timeout_ms equals modal_app.py's declared timeout" do
      [[_, seconds]] = Regex.scan(~r/^\s*timeout=(\d+),?\s*$/m, File.read!(@modal_app_path))

      declared_ms = String.to_integer(seconds) * 1_000

      assert VisionClient.modal_function_timeout_ms() == declared_ms,
             "Stacks.AI.Client mirrors Modal's function timeout as " <>
               "#{VisionClient.modal_function_timeout_ms()}ms, but modal_app.py declares " <>
               "timeout=#{seconds} (#{declared_ms}ms). The two are one number in two languages; " <>
               "a comment claiming they agree is what let them disagree by 90 seconds. Update " <>
               "@modal_function_timeout_ms in apps/core/lib/stacks/ai/client.ex."
    end
  end

  describe "a give-up is countable (or the deadline above is unfalsifiable)" do
    test "reason_class/1 maps a real receive timeout to :timeout" do
      assert VisionClient.reason_class(%Finch.TransportError{
               reason: :timeout,
               source: %Mint.TransportError{reason: :timeout}
             }) == :timeout

      assert VisionClient.reason_class(%Mint.TransportError{reason: :timeout}) == :timeout
    end

    test "reason_class/1 is total and closed, so it is safe as a metric label" do
      closed = [:timeout, :closed, :unreachable, :protocol, :other]

      terms = [
        %Finch.TransportError{reason: :timeout, source: nil},
        %Finch.TransportError{reason: :closed, source: nil},
        %Finch.TransportError{reason: :econnrefused, source: nil},
        %Finch.TransportError{reason: :nxdomain, source: nil},
        %Finch.TransportError{reason: :something_new_from_a_dep_bump, source: nil},
        %Mint.TransportError{reason: :ehostunreach},
        %Finch.HTTPError{reason: :invalid_status_line, module: Mint.HTTP1, source: nil},
        %Finch.Error{reason: :connection_process_went_down},
        :malformed_response,
        {:unexpected, "tuple"},
        %{image_url: "https://example.test/u/9780241543382.jpg"}
      ]

      for term <- terms do
        assert VisionClient.reason_class(term) in closed,
               "reason_class/1 must return a member of #{inspect(closed)} for every term the " <>
                 "socket layer can produce — it is a metric LABEL, and an open return value " <>
                 "is unbounded cardinality plus a PII leak. #{inspect(term)} returned " <>
                 "#{inspect(VisionClient.reason_class(term))}"
      end
    end

    test "a distinct class survives: a give-up is not lumped with an unreachable host" do
      refute VisionClient.reason_class(%Finch.TransportError{reason: :timeout, source: nil}) ==
               VisionClient.reason_class(%Finch.TransportError{
                 reason: :econnrefused,
                 source: nil
               }),
             "if a deadline hit and a refused socket share a class, the counter cannot answer " <>
               "the only question it exists for: did calls reach the client's deadline?"
    end

    test "the counter is registered, classified, and tagged by endpoint and class" do
      metric =
        StacksPlugin.event_metrics([])
        |> Enum.flat_map(& &1.metrics)
        |> Enum.find(&(Enum.join(&1.name, "_") == @family))

      assert metric, "no metric registered under #{@family}"
      assert %Telemetry.Metrics.Counter{} = metric
      assert metric.event_name == @event
      assert metric.tags == [:endpoint, :reason_class]

      assert MetricAudience.audience(@family) == :public,
             "a give-up count is an aggregate over two bounded atoms; leaving it unclassified " <>
               "means fail-closed hides it from every dashboard"
    end

    test "emitting the real event exports a series (the metric is ATTACHED)" do
      :telemetry.execute(
        @event,
        %{duration: System.convert_time_unit(330_000, :millisecond, :native)},
        %{
          endpoint: @isolating_endpoint,
          kind: :error,
          reason: %Finch.TransportError{reason: :timeout, source: nil},
          reason_class: :timeout
        }
      )

      output = scrape()

      assert output =~ @family,
             "expected #{@family} in PromEx output — a Telemetry.Metrics struct in a plugin is " <>
               "inert until PromEx attaches a handler for its event_name, and this event has " <>
               "been emitted-and-unconsumed since the client was written. Got:\n#{output}"

      found = series(output, endpoint: @isolating_endpoint, reason_class: "timeout")

      assert found != [],
             "expected a #{@family} series labelled endpoint=\"#{@isolating_endpoint}\" " <>
               "reason_class=\"timeout\", got:\n#{output}"

      assert Enum.any?(found, fn {_block, value} -> String.to_integer(value) >= 1 end)
    end

    test "the open `reason` term is DROPPED, never exported as a label" do
      :telemetry.execute(
        @event,
        %{duration: 1},
        %{
          endpoint: @isolating_endpoint,
          kind: :error,
          reason: {:transport, %{image_url: "https://example.test/9780241543382.jpg"}},
          reason_class: :other,
          user_id: "11111111-1111-1111-1111-111111111111"
        }
      )

      output = scrape()

      blocks =
        output
        |> series(endpoint: @isolating_endpoint, reason_class: "other")
        |> Enum.map(fn {block, _} -> block end)

      assert blocks != [], "expected an exported series to inspect, got:\n#{output}"

      allowed = MapSet.new(["endpoint", "reason_class"])

      for block <- blocks do
        leaked = MapSet.difference(label_keys(block), allowed)

        assert MapSet.size(leaked) == 0,
               "these metadata keys became metric LABELS: #{inspect(MapSet.to_list(leaked))} — " <>
                 "only the bounded endpoint/reason_class pair may reach the sink: #{block}"
      end

      refute output =~ "9780241543382"
      refute output =~ "example.test"
      refute output =~ "11111111-1111-1111-1111-111111111111"
    end
  end

  defp scrape do
    Process.sleep(50)
    output = PromEx.get_metrics(Core.PromEx)
    refute output == :prom_ex_down, "Core.PromEx must be running for this test"
    output
  end

  defp series(output, pairs) do
    for line <- String.split(output, "\n"),
        [_, block, value] <- Regex.scan(~r/^#{Regex.escape(@family)}\{([^}]*)\}\s+(\S+)$/, line),
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
end
