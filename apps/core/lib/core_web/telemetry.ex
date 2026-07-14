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
    :scraper_fuse,
    :brave_fuse,
    :searxng_fuse,
    :r2_fuse
  ]

  @route_group_handler_id "stacks-route-group-router-dispatch-stop"
  @slow_query_handler_id "stacks-slow-query-log"
  @oban_worker_tag_handler_id "stacks-oban-worker-tag"

  # Process-dict key used to tag the current Oban worker. Set at
  # [:oban, :job, :start] and cleared at [:oban, :job, :stop] /
  # [:oban, :job, :exception] so any Ecto query fired from within
  # Oban.Worker.perform/1 is tagged with the worker module name.
  # HTTP paths (no job in scope) get tagged as "http".
  @current_worker_key :stacks_current_oban_worker

  # Threshold for slow-query logging. Queries with Ecto total_time
  # (queue + query + decode) above this fire a Logger.warning with the
  # SQL source + params-size + pool queue time. Chosen to match Ecto's
  # own default "slow" perception: anything 500ms+ is noteworthy on a
  # primarily-OLTP workload. Override via the `:slow_query_threshold_ms`
  # application env at startup for tuning without a code change.
  @default_slow_query_threshold_ms 500

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    attach_route_group_handler()
    attach_oban_worker_tag_handler()
    attach_slow_query_handler()

    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # NOTE: The three `[:stacks, ...]` custom telemetry series
  # (`:router_dispatch.stop`, `:upload.terminal`, `:fuse.state`) are now
  # wired into Prometheus via `Core.PromEx.Plugins.Stacks` (see Issue
  # #139). PromEx consumes plugin-returned metrics only, so defining them
  # here too would either be dead weight or double-count. If a future
  # change adds a second reporter (e.g. `TelemetryMetricsPrometheus.Core`
  # attached directly), re-declare the three series here and in the
  # plugin — don't point them at the same reporter twice.
  def metrics do
    [
      # ── Phoenix ───────────────────────────────────────────────────────
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
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
      # `stacks.fuse.state` gauge is exported by `Core.PromEx.Plugins.Stacks`
      # (see Issue #139); the series here would be redundant for PromEx.

      # ── Upload pipeline (Issue #136) ─────────────────────────────────
      # `stacks.upload.terminal` counter is exported by
      # `Core.PromEx.Plugins.Stacks` (see Issue #139).

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
      ),

      # ── Visibility & Privacy (Issue #197 / #122 §12) ─────────────────
      counter("stacks.visibility.profile_change.count",
        event_name: [:stacks, :visibility, :profile_change],
        tags: [:direction],
        description: "Profile-visibility changes, tagged tighten/loosen/same"
      ),
      counter("stacks.visibility.recap.count",
        event_name: [:stacks, :visibility, :recap],
        tags: [:outcome],
        description: "Visibility recap job outcomes (capped/noop/error)"
      ),
      sum("stacks.visibility.recap.bookshelves_capped",
        event_name: [:stacks, :visibility, :recap],
        measurement: :bookshelves_capped,
        tags: [:outcome],
        description: "Bookshelves capped by the visibility recap job"
      ),
      sum("stacks.visibility.recap.placements_capped",
        event_name: [:stacks, :visibility, :recap],
        measurement: :placements_capped,
        tags: [:outcome],
        description: "Placements capped by the visibility recap job"
      ),
      sum("stacks.visibility.recap.posts_capped",
        event_name: [:stacks, :visibility, :recap],
        measurement: :posts_capped,
        tags: [:outcome],
        description: "Blog posts capped by the visibility recap job"
      ),
      counter("stacks.visibility.ceiling_rejection.count",
        event_name: [:stacks, :visibility, :ceiling_rejection],
        tags: [:resource_type],
        description: "Visibility-ceiling rejections by resource type"
      ),

      # ── Social: blocking (Issue #197 / #122 §12) ─────────────────────
      counter("stacks.social.block.count",
        event_name: [:stacks, :social, :block],
        description: "Successful user blocks"
      ),
      counter("stacks.social.unblock.count",
        event_name: [:stacks, :social, :unblock],
        description: "Successful user unblocks"
      ),
      counter("stacks.social.block_error.count",
        event_name: [:stacks, :social, :block_error],
        tags: [:reason],
        description: "Block errors by reason (cannot_block_self/already_blocked)"
      ),

      # ── Rate limiting (Issue #197 — generic, tagged by bucket) ───────
      counter("stacks.rate_limit.hit.count",
        event_name: [:stacks, :rate_limit, :hit],
        tags: [:bucket],
        description: "Rate-limit rejections tagged by bucket (incl. :social)"
      ),

      # ── ViewAs preview (Issue #197 / #122 §12) ───────────────────────
      counter("stacks.view_as.usage.count",
        event_name: [:stacks, :view_as, :usage],
        tags: [:perspective],
        description: "ViewAs usage by simulated perspective"
      ),
      counter("stacks.view_as.error.count",
        event_name: [:stacks, :view_as, :error],
        tags: [:reason, :phase],
        description: "ViewAs errors by reason + phase (parse/authorize)"
      ),

      # ── Search-engine privacy (Issue #197 / #122 §12) ────────────────
      counter("stacks.crawler.robots_fetch.count",
        event_name: [:stacks, :crawler, :robots_fetch],
        description: "robots.txt fetch count"
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

  @doc """
  Attach a telemetry handler that logs Ecto queries exceeding a wall-
  clock threshold. Listens on both `Core.Repo` and `Core.ObanRepo`
  `[:query]` events. Idempotent — safe to call on supervisor restart.

  Why not just bump Ecto's `:log` level to `:info`? That logs EVERY
  query, which is too noisy in prod (~200 queries/sec steady-state
  during probe load). Slow-only is what operators need to find the
  actual hot-spots causing db_pool_queue saturation.
  """
  @spec attach_slow_query_handler() :: :ok
  def attach_slow_query_handler do
    :telemetry.detach(@slow_query_handler_id)

    :telemetry.attach_many(
      @slow_query_handler_id,
      [
        [:core, :repo, :query],
        [:core, :oban_repo, :query]
      ],
      &__MODULE__.handle_slow_query/4,
      nil
    )

    :ok
  end

  @doc false
  def handle_slow_query(_event, measurements, metadata, _config) do
    total_time = Map.get(measurements, :total_time, 0)
    source = Map.get(metadata, :source) || "(raw)"
    repo_atom = Map.get(metadata, :repo, :unknown)
    worker = Process.get(@current_worker_key) || "http"

    # Always-emit: per-query duration tagged by worker + source + repo.
    # Distribution picked up by Core.PromEx.Plugins.Stacks and exported
    # as `stacks_repo_query_duration_milliseconds_{bucket,sum,count}`.
    # The `worker` tag is "http" for queries issued from the request
    # pipeline, "Stacks.Workers.XxxJob" for queries issued from Oban
    # workers. Answers "which worker's business-logic queries are
    # dominating Core.Repo's pool time?" — indirectly a proxy for
    # connection-hold time per worker.
    #
    # Event path matches `event_name:` in the PromEx plugin. The
    # `:duration, :milliseconds` suffix is part of the METRIC name
    # only — Telemetry.Metrics strips it when listening.
    :telemetry.execute(
      [:stacks, :repo, :query, :duration],
      %{duration: total_time},
      %{
        worker: worker,
        source: source,
        repo: Atom.to_string(repo_atom)
      }
    )

    # Slow-query log (throttled by threshold so we only log the
    # interesting ones).
    threshold_native =
      System.convert_time_unit(
        Application.get_env(:core, :slow_query_threshold_ms, @default_slow_query_threshold_ms),
        :millisecond,
        :native
      )

    if total_time > threshold_native do
      total_ms = System.convert_time_unit(total_time, :native, :millisecond)
      queue_ms = ms(Map.get(measurements, :queue_time, 0))
      query_ms = ms(Map.get(measurements, :query_time, 0))
      decode_ms = ms(Map.get(measurements, :decode_time, 0))
      sql_preview = metadata |> Map.get(:query, "") |> truncate_sql()

      require Logger

      Logger.warning(
        "slow_query repo=#{inspect(repo_atom)} worker=#{worker} source=#{source} " <>
          "total=#{total_ms}ms queue=#{queue_ms}ms query=#{query_ms}ms decode=#{decode_ms}ms " <>
          "sql=#{sql_preview}"
      )
    end

    :ok
  end

  @doc """
  Attach a telemetry handler that keeps `@current_worker_key` in the
  process dictionary in sync with the currently-executing Oban job
  worker module. Read by `handle_slow_query/4` to tag the per-query
  duration histogram.

  Oban runs each job in a dedicated process via
  `Oban.Worker.perform/1`, so the process-dict scoping works: one
  worker per process, cleared on completion.
  """
  @spec attach_oban_worker_tag_handler() :: :ok
  def attach_oban_worker_tag_handler do
    :telemetry.detach(@oban_worker_tag_handler_id)

    :telemetry.attach_many(
      @oban_worker_tag_handler_id,
      [
        [:oban, :job, :start],
        [:oban, :job, :stop],
        [:oban, :job, :exception]
      ],
      &__MODULE__.handle_oban_job_lifecycle/4,
      nil
    )

    :ok
  end

  @doc false
  def handle_oban_job_lifecycle([:oban, :job, :start], _measurements, metadata, _config) do
    worker = metadata |> Map.get(:job, %{}) |> Map.get(:worker, "unknown")
    Process.put(@current_worker_key, worker)
    :ok
  end

  def handle_oban_job_lifecycle([:oban, :job, _stop_or_exc], _measurements, _metadata, _config) do
    Process.delete(@current_worker_key)
    :ok
  end

  defp ms(native) when is_integer(native) do
    System.convert_time_unit(native, :native, :millisecond)
  end

  defp ms(_), do: 0

  # Cap SQL at 200 chars so a slow 20KB bulk INSERT doesn't drown the
  # log line. Truncation marker keeps grep-ability for the full query
  # shape without the parameter blob.
  defp truncate_sql(sql) when is_binary(sql) do
    if byte_size(sql) > 200 do
      binary_part(sql, 0, 200) <> "…"
    else
      sql
    end
  end

  defp truncate_sql(_), do: ""

  @doc false
  def handle_router_dispatch_stop(_event, measurements, %{conn: conn} = metadata, _config)
      when is_map(conn) do
    group = conn.private[:route_group] || conn.assigns[:route_group] || :other
    enriched = Map.put(metadata, :route_group, group)
    :telemetry.execute([:stacks, :router_dispatch, :stop], measurements, enriched)
  end

  def handle_router_dispatch_stop(_event, _measurements, _metadata, _config), do: :ok
end
