defmodule Core.Repo.Migrations.AddObanJobsQueueStateIndex do
  @moduledoc """
      Partial index on `oban_jobs(queue, state)` for non-final states.
      PromEx's Oban plugin polls `SELECT queue, state, COUNT(id) … GROUP BY`
      every 10s from a saturated pool (~75ms each, caught by slow-query
      telemetry). The index makes it an index-only scan; the partial WHERE
      keeps completed/cancelled/discarded rows (the vast majority) out.
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
