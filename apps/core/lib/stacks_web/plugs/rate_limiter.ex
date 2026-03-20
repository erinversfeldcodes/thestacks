defmodule StacksWeb.Plugs.RateLimiter do
  @moduledoc """
  ETS-backed sliding window rate limiter Plug.

  - Global endpoints: 1000 requests / 60 seconds per IP
  - Auth endpoints (`:auth` bucket): 5 requests / 60 seconds per IP
  - Upload endpoints (`:upload` bucket): 10 requests / 60 seconds per authenticated user
  - Social endpoints (`:social` bucket): 20 requests / 60 seconds per authenticated user
  - Password change (`:password_change` bucket): 3 requests / 60 seconds per IP

  The ETS table is managed by `StacksWeb.Plugs.RateLimiter.Server` which
  must be started in the supervision tree before this plug runs.

  Usage:
    plug StacksWeb.Plugs.RateLimiter
    plug StacksWeb.Plugs.RateLimiter, bucket: :auth
    plug StacksWeb.Plugs.RateLimiter, bucket: :upload
    plug StacksWeb.Plugs.RateLimiter, bucket: :social
  """

  require Logger

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @table :rate_limiter
  @window_ms 60_000
  @global_limit 1_000
  @auth_limit 5
  @upload_limit 10
  @password_change_limit 3
  @social_limit 20

  def init(opts), do: opts

  def call(conn, opts) do
    if Application.get_env(:core, :rate_limiting_enabled, true) do
      do_rate_check(conn, opts)
    else
      conn
    end
  end

  defp do_rate_check(conn, opts) do
    bucket = Keyword.get(opts, :bucket, :global)
    key = get_key(conn, bucket)
    limit = get_limit(bucket)

    cond do
      not ets_available?() ->
        Logger.error(
          "RateLimiter: ETS table unavailable — request allowed through without limiting"
        )

        conn

      rate_limited?(key, bucket, limit) ->
        conn
        |> put_status(429)
        |> put_resp_header("retry-after", "60")
        |> json(%{error: "rate_limit_exceeded"})
        |> halt()

      true ->
        conn
    end
  end

  defp get_limit(:auth), do: Application.get_env(:core, :rate_limit_auth, @auth_limit)
  defp get_limit(:upload), do: @upload_limit
  defp get_limit(:password_change), do: @password_change_limit
  defp get_limit(:social), do: @social_limit
  defp get_limit(_), do: @global_limit

  # Upload and social buckets key on user ID so the limit is per-user, not per-IP.
  defp get_key(conn, bucket) when bucket in [:upload, :social] do
    case conn.assigns[:guardian_default_resource] do
      nil -> get_ip(conn)
      user -> "user:#{user.id}"
    end
  end

  defp get_key(conn, _), do: get_ip(conn)

  defp ets_available? do
    :ets.whereis(@table) != :undefined
  end

  defp rate_limited?(key, bucket, limit) do
    now_ms = System.system_time(:millisecond)
    key = {key, bucket}

    case :ets.lookup(@table, key) do
      [] ->
        :ets.insert(@table, {key, [{now_ms}]})
        false

      [{^key, timestamps}] ->
        cutoff = now_ms - @window_ms
        recent = Enum.filter(timestamps, fn {ts} -> ts > cutoff end)
        count = length(recent)

        if count >= limit do
          true
        else
          :ets.insert(@table, {key, [{now_ms} | recent]})
          false
        end
    end
  end

  defp get_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [ip | _] -> ip
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defmodule Server do
    @moduledoc """
    GenServer that creates and maintains the ETS table used by `StacksWeb.Plugs.RateLimiter`.
    Add this to the supervision tree, not `RateLimiter` itself.
    """

    use GenServer

    require Logger

    @table :rate_limiter
    @window_ms 60_000
    @cleanup_interval_ms 120_000

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
    end

    @impl GenServer
    def init(:ok) do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      # runtime.exs runs before Fly.io secrets are injected into the process
      # environment, so Application.get_env(:core, :rate_limit_auth) is not set
      # by the time the plug reads it. Apply the override here, where secrets
      # are guaranteed to be present.
      if limit = System.get_env("RATE_LIMIT_AUTH") do
        Application.put_env(:core, :rate_limit_auth, String.to_integer(limit))
      end

      schedule_cleanup()
      {:ok, %{}}
    end

    @impl GenServer
    def handle_info(:cleanup, state) do
      cleanup_old_entries()
      schedule_cleanup()
      {:noreply, state}
    end

    defp cleanup_old_entries do
      now_ms = System.system_time(:millisecond)
      cutoff = now_ms - @window_ms

      :ets.foldl(
        fn {key, timestamps}, _acc ->
          recent = Enum.filter(timestamps, fn {ts} -> ts > cutoff end)

          if recent == [] do
            :ets.delete(@table, key)
          else
            :ets.insert(@table, {key, recent})
          end
        end,
        :ok,
        @table
      )
    end

    defp schedule_cleanup do
      Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    end
  end
end
