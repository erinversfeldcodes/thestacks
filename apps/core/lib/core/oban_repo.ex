defmodule Core.ObanRepo do
  @moduledoc """
    Dedicated Ecto repo for Oban workers: same Postgres database as
    `Core.Repo`, separate connection pool, so a job burst can't starve HTTP
    request handlers of connections (the 2026-04-20 `db_pool_queue_p95_ms`
    breach). Purely a pool-layer split — schemas and data model unchanged.
    Pool size: `OBAN_POOL_SIZE` (default 15, `config/runtime.exs`).
  """

  use Ecto.Repo,
    otp_app: :core,
    adapter: Ecto.Adapters.Postgres

  @impl true
  def init(_type, config) do
    {:ok, Keyword.put(config, :migration_primary_key, type: :binary_id)}
  end
end
