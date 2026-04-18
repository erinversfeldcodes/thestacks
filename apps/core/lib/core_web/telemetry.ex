defmodule CoreWeb.Telemetry do
  @moduledoc """
  Supervises the `telemetry_poller` that drives custom gauges, declares the
  app's metric series, and wires request-scoped tags from `conn.private` into
  the Phoenix dispatch telemetry metadata.
  """

  use Supervisor
  import Telemetry.Metrics

  # Fuses whose state is exported as a gauge. Must match the keys installed by
  # `Stacks.CircuitBreakers` — update both lists in lockstep.
  @managed_fuses [
    :vision_fuse,
    :together_ai_fuse,
    :open_library_fuse,
    :google_books_fuse,
    :scraper_fuse
  ]

  @route_group_handler_id "stacks-route-group-router-dispatch-stop"

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    attach_route_group_handler()

    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # ── Phoenix ───────────────────────────────────────────────────────
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      # Phoenix emits `[:phoenix, :router_dispatch, :stop]` natively without
      # a `:route_group` key. `CoreWeb.Telemetry.handle_router_dispatch_stop/4`
      # listens on that event and re-emits under the Stacks-namespaced event
      # below with `:route_group` merged in, so reporters attached to the
      # series below do NOT double-count Phoenix's original emission.
      summary("stacks.router_dispatch.stop.duration",
        event_name: [:stacks, :router_dispatch, :stop],
        measurement: :duration,
        tags: [:route, :route_group],
        unit: {:native, :millisecond}
      ),

      # ── Ecto ──────────────────────────────────────────────────────────
      summary("core.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("core.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("core.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("core.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),

      # ── Vision Client (Issue #129) ───────────────────────────────────
      counter("stacks.vision.request.start.system_time",
        tags: [:endpoint],
        description: "Count of vision request starts"
      ),
      summary("stacks.vision.request.stop.duration",
        tags: [:endpoint, :status],
        unit: {:native, :millisecond},
        description: "Vision request duration"
      ),
      counter("stacks.vision.request.exception.duration",
        tags: [:endpoint, :kind],
        description: "Count of vision request exceptions"
      ),

      # ── Fuse (Issue #129 + Issue #136) ───────────────────────────────
      counter("stacks.fuse.melt.count",
        event_name: [:stacks, :fuse, :melt],
        tags: [:fuse_name],
        description: "Fuse melt events (circuit still closed)"
      ),
      counter("stacks.fuse.blown.count",
        event_name: [:stacks, :fuse, :blown],
        tags: [:fuse_name],
        description: "Fuse blown events (circuit opened)"
      ),
      last_value("stacks.fuse.state.state",
        event_name: [:stacks, :fuse, :state],
        measurement: :state,
        tags: [:fuse_name],
        description: "Current fuse state: 1 = healthy, 0 = blown"
      ),

      # ── Upload pipeline (Issue #136) ─────────────────────────────────
      counter("stacks.upload.terminal.count",
        event_name: [:stacks, :upload, :terminal],
        measurement: :count,
        tags: [:outcome],
        description: "Uploaded image terminal outcome count (resolved/rejected/timeout)"
      ),

      # ── Budget Tracker (Issue #129) ──────────────────────────────────
      sum("stacks.budget.cost_recorded.amount_cents",
        tags: [:provider],
        description: "AI API cost recorded in cents"
      ),
      counter("stacks.budget.limit_exceeded.count",
        event_name: [:stacks, :budget, :limit_exceeded],
        tags: [:provider, :type],
        description: "Budget limit exceeded events"
      ),

      # ── Costs Context (Issue #129) ───────────────────────────────────
      sum("stacks.costs.recorded.amount_cents",
        tags: [:category, :service],
        description: "Platform cost recorded in cents"
      )
    ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :poll_fuse_state, []}
    ]
  end

  @doc """
  Emit one `[:stacks, :fuse, :state]` gauge event per managed fuse.

  Each event carries `%{state: 0 | 1}` — 1 if the fuse is healthy
  (`:fuse.ask/2` returns `:ok`), 0 otherwise — and `%{fuse_name: atom()}`
  metadata.

  Called every 10s by `:telemetry_poller` and feeds the SLO gate's
  "fuse open count = 0" threshold.
  """
  @spec poll_fuse_state() :: :ok
  def poll_fuse_state do
    Enum.each(@managed_fuses, fn fuse_name ->
      state =
        case :fuse.ask(fuse_name, :sync) do
          :ok -> 1
          _ -> 0
        end

      :telemetry.execute(
        [:stacks, :fuse, :state],
        %{state: state},
        %{fuse_name: fuse_name}
      )
    end)
  end

  @doc """
  Attach the telemetry handler that observes
  `[:phoenix, :router_dispatch, :stop]` and re-emits a Stacks-namespaced
  `[:stacks, :router_dispatch, :stop]` event with `:route_group` copied out
  of `conn.private`. Idempotent — safe to call on supervisor restart.

  The re-emit uses a distinct event name (not Phoenix's) so any
  `Telemetry.Metrics` reporter attached to the Stacks series does not
  double-count Phoenix's original emission.
  """
  @spec attach_route_group_handler() :: :ok
  def attach_route_group_handler do
    # Detach first so a crash+restart does not leave an old handler pointing at
    # a dead PID. `:telemetry.detach/1` is a no-op if the handler is not attached.
    :telemetry.detach(@route_group_handler_id)

    :telemetry.attach(
      @route_group_handler_id,
      [:phoenix, :router_dispatch, :stop],
      &__MODULE__.handle_router_dispatch_stop/4,
      nil
    )

    :ok
  end

  @doc false
  def handle_router_dispatch_stop(_event, measurements, %{conn: conn} = metadata, _config)
      when is_map(conn) do
    group = conn.private[:route_group] || conn.assigns[:route_group] || :other
    enriched = Map.put(metadata, :route_group, group)
    :telemetry.execute([:stacks, :router_dispatch, :stop], measurements, enriched)
  end

  def handle_router_dispatch_stop(_event, _measurements, _metadata, _config), do: :ok
end
