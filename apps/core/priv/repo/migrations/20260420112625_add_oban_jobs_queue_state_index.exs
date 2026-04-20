defmodule Core.Repo.Migrations.AddObanJobsQueueStateIndex do
  @moduledoc """
  Partial index on `oban_jobs(queue, state)` for non-final states.

  PromEx's Oban plugin polls every 10s with:

      SELECT queue, state, COUNT(id)
      FROM oban_jobs
      GROUP BY queue, state

  On 2026-04-20 the slow-query telemetry (see
  `CoreWeb.Telemetry.attach_slow_query_handler/0`) caught this query
  at ~75ms query time. It's not catastrophic but it runs every 10s,
  on every core machine, from a connection in a saturated pool — the
  cumulative cost is 15s/day of DB connection time purely for this
  metric.

  A (queue, state) index makes the GROUP BY an index-only scan.
  `WHERE state IN (...)` limits the index to live/retryable jobs —
  completed/cancelled/discarded rows (which make up the bulk of the
  table once a workload has been running a while) are excluded, so
  the index stays small even as history grows.

  The pruner (`Oban.Plugins.Pruner` in `config/config.exs`) will
  periodically trim old finished jobs from the table body; the
  partial index naturally excludes everything it would prune
  anyway.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create_if_not_exists index(
                           :oban_jobs,
                           [:queue, :state],
                           name: :oban_jobs_queue_state_idx,
                           concurrently: true,
                           where: "state IN ('available', 'scheduled', 'executing', 'retryable')"
                         )
  end
end
