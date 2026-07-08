defmodule Core.ObanRepo do
  @moduledoc """
  Dedicated Ecto repo for Oban workers.

  Points at the same Postgres database as `Core.Repo` but owns its own
  connection pool. Decouples background-job DB work from the hot-path
  HTTP request handlers so a burst of jobs can't starve request
  handlers of connections (which was the direct cause of the 2026-04-20
  `db_pool_queue_p95_ms` breach).

  Oban reads/writes to `public.oban_jobs` + emits events via
  `Stacks.Events.emit_safe/1` which writes to `op.event_log` — both
  tables live in the same database that `Core.Repo` uses, so nothing
  else changes from the schema or data model perspective. The split is
  purely at the connection-pool layer.

  Pool size is configured via `OBAN_POOL_SIZE` env var (default 15);
  see `config/runtime.exs`.
  """

  use Ecto.Repo,
    otp_app: :core,
    adapter: Ecto.Adapters.Postgres

  @impl true
  def init(_type, config) do
    {:ok, Keyword.put(config, :migration_primary_key, type: :binary_id)}
  end
end
