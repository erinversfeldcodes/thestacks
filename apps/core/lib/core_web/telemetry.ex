defmodule CoreWeb.Telemetry do
  @moduledoc """
      Supervises the `telemetry_poller` that drives custom gauges, declares the
      app's metric series, and wires request-scoped tags from `conn.private` into
      the Phoenix dispatch telemetry metadata.
  """

  use Supervisor
  import Telemetry.Metrics

  @managed_fuses [
    :vision_fuse,
    :together_ai_fuse,
    :open_library_fuse,
    :google_books_fuse,
    :scraper_fuse,
    :brave_fuse,
    :searxng_fuse,
    :r2_fuse,
    :nominatim_fuse,
    :neon_fuse,
    :resend_fuse,
    :log_shipper_fuse
  ]

  @route_group_handler_id "stacks-route-group-router-dispatch-stop"
  @slow_query_handler_id "stacks-slow-query-log"
  @oban_worker_tag_handler_id "stacks-oban-worker-tag"

  @current_worker_key :stacks_current_oban_worker

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

  def metrics do
    [
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
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
      sum("stacks.budget.cost_recorded.amount_cents",
        tags: [:provider],
        description: "AI API cost recorded in cents"
      ),
      counter("stacks.budget.limit_exceeded.count",
        event_name: [:stacks, :budget, :limit_exceeded],
        tags: [:provider, :type],
        description: "Budget limit exceeded events"
      ),
      sum("stacks.costs.recorded.amount_cents",
        tags: [:category, :service],
        description: "Platform cost recorded in cents"
      ),
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
        description:
          "Block errors by reason (cannot_block_self/not_found/already_blocked/invalid)"
      ),
      counter("stacks.rate_limit.rejected.count",
        event_name: [:stacks, :rate_limit, :rejected],
        tags: [:bucket],
        description: "Rate-limit rejections tagged by bucket (incl. :social, :auth)"
      ),
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
      counter("stacks.crawler.robots_fetch.count",
        event_name: [:stacks, :crawler, :robots_fetch],
        description: "robots.txt fetch count"
      )
    ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :poll_fuse_state, []},
      {__MODULE__, :poll_db_watchdog, []},
      {__MODULE__, :poll_log_shipper_keepalive, []}
    ]
  end

  @doc """
      Keepalive ping that keeps the log shipper's lifecycle coupled to ours.

      The shipper subscribes to Fly's log stream, which has no replay — logs
      emitted while it sleeps are gone — and Fly only auto-starts machines on
      proxied traffic, which a log tailer never receives on its own. This GET
      against its Flycast health endpoint IS that traffic: the first ping
      after our boot wakes the shipper, each 10s tick resets its idle timer,
      and ~5min after we go quiet it sleeps again. Fire-and-forget: a dead
      shipper must never affect us (the daily billing sweep reports it).

      No-op unless `:log_shipper_keepalive_url` is configured (prod only).
  """
  @spec poll_log_shipper_keepalive() :: :ok
  def poll_log_shipper_keepalive do
    case Application.get_env(:core, :log_shipper_keepalive_url) do
      url when is_binary(url) and url != "" ->
        case ping_log_shipper(url) do
          :ok ->
            :ok

          {:error, _reason} ->
            # log-shipper analogue of the db watchdog: a shipper we cannot
            # reach while we are awake means logs are being lost right now —
            # melt so the fuse gauge (and the public breakers signal) shows
            # it. One cold-start miss per wake stays under the blow
            # threshold; a dead shipper blows it within a minute.
            Stacks.CircuitBreakers.melt(:log_shipper_fuse)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp ping_log_shipper(url) do
    request = Finch.build(:get, url <> "/health")

    case Finch.request(request, Stacks.Finch, receive_timeout: 2_000, request_timeout: 2_000) do
      {:ok, %Finch.Response{status: 200}} -> :ok
      {:ok, %Finch.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @doc """
      Active database watchdog: pings the database every poll tick and melts
      `:neon_fuse` on failure.

      Every other fuse melts under real traffic, but a database outage on a
      scale-to-zero app with no visitors produces NO traffic — nothing would
      melt, the fuse-state gauge would keep reporting healthy, and the outage
      would be invisible on every dashboard (exactly what happened when the
      free-tier compute quota was exhausted). The melt threshold (5/60s at a
      10s poll) blows the fuse within about a minute of the database going
      away; the standard probe loop closes it again on recovery.

      Disabled via `:db_watchdog_enabled` in test — the SQL sandbox would
      report ownership errors as outages.
  """
  @spec poll_db_watchdog() :: :ok
  def poll_db_watchdog do
    if Application.get_env(:core, :db_watchdog_enabled, true) do
      case db_ping().() do
        :ok -> :ok
        {:error, _reason} -> Stacks.CircuitBreakers.melt(:neon_fuse)
      end
    end

    :ok
  end

  defp db_ping do
    Application.get_env(:core, :db_watchdog_ping, &__MODULE__.default_db_ping/0)
  end

  @doc false
  @spec default_db_ping() :: :ok | {:error, term()}
  def default_db_ping do
    case Core.Repo.query("SELECT 1", [], timeout: 2_000) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @doc """
      Emit one `[:stacks,:fuse,:state]` gauge event per managed fuse.

      Each event carries `%{state: 0 | 1}` — 1 if the fuse is healthy
      (`:fuse.ask/2` returns `:ok`), 0 otherwise — and `%{fuse_name: atom}`
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
      `[:phoenix,:router_dispatch,:stop]` and re-emits a Stacks-namespaced
      `[:stacks,:router_dispatch,:stop]` event with `:route_group` copied out
      of `conn.private`. Idempotent — safe to call on supervisor restart.

      The re-emit uses a distinct event name (not Phoenix's) so any
      `Telemetry.Metrics` reporter attached to the Stacks series does not
      double-count Phoenix's original emission.
  """
  @spec attach_route_group_handler() :: :ok
  def attach_route_group_handler do
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
