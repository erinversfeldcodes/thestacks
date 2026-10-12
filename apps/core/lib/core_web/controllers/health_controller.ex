defmodule CoreWeb.HealthController do
  @moduledoc """
      Liveness (`/api/health`) and readiness (`/api/health/ready`).

      Liveness stays static on purpose: Fly restarts machines on failed
      checks, and restart-looping the app during a database outage helps
      nobody. Readiness actually touches the database and 503s when it is
      unreachable — point uptime monitors and the deploy SLO gate here, so
      a database outage cannot report green (it did once: the quota outage
      served 200s from this controller the whole way through).
  """

  use CoreWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok", service: "core"})
  end

  def ready(conn, _params) do
    case readiness_check().() do
      :ok ->
        json(conn, %{status: "ok", service: "core", db: true})

      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "degraded", service: "core", db: false})
    end
  end

  defp readiness_check do
    Application.get_env(:core, :readiness_check, &__MODULE__.db_ready/0)
  end

  @doc false
  @spec db_ready() :: :ok | {:error, term()}
  def db_ready do
    case Core.Repo.query("SELECT 1", [], timeout: 2_000) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end
end
