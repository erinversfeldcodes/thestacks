defmodule CoreWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
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
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
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

      # ── Fuse (Issue #129) ────────────────────────────────────────────
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
    []
  end
end
