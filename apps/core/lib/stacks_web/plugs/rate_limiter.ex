defmodule StacksWeb.Plugs.RateLimiter do
  @moduledoc """
      ETS-backed sliding-window rate limiter. Buckets: global 1000/60s per
      IP; `:auth` 60/60s per IP; `:upload` 120/60s per user; `:social` 20/60s
      per user; `:public` 200/60s per IP (`RATE_LIMIT_PUBLIC`);
      `:password_change` 20/60s per IP; `:feedback` 10/60s per user.

      Sizing: per-IP limiting is a weak credential-stuffing defence (attackers
      rotate IPs; NATs share them), so auth values slow naive scripts without
      locking out shared-address users — the real defences are per-ACCOUNT
      lockout (`Accounts.authenticate_user/2`) and Argon2 cost. 429s carry
      `retry-after`. State is per-node ETS: resets on deploy, unshared across
      machines — acceptable for the current single-machine posture.
  """

  require Logger

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @table :rate_limiter
  @window_ms 60_000
  @global_limit 1_000
  @auth_limit 60
  @upload_limit 120
  @password_change_limit 20
  @social_limit 20
  @public_limit 200
  @admin_limit 30
  @e2e_helper_limit 10
  @feedback_limit 10

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
        :telemetry.execute([:stacks, :rate_limit, :rejected], %{count: 1}, %{bucket: bucket})

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

  defp get_limit(:password_change),
    do: Application.get_env(:core, :rate_limit_password_change, @password_change_limit)

  defp get_limit(:social), do: @social_limit
  defp get_limit(:public), do: Application.get_env(:core, :rate_limit_public, @public_limit)
  defp get_limit(:admin), do: Application.get_env(:core, :rate_limit_admin, @admin_limit)

  defp get_limit(:e2e_helper),
    do: Application.get_env(:core, :rate_limit_e2e_helper, @e2e_helper_limit)

  defp get_limit(:feedback), do: Application.get_env(:core, :rate_limit_feedback, @feedback_limit)

  defp get_limit(_), do: @global_limit

  defp get_key(conn, bucket) when bucket in [:upload, :social, :feedback] do
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
    {ip, source} =
      case get_req_header(conn, "fly-client-ip") do
        [ip | _] when ip != "" ->
          {ip, :trusted_proxy}

        _ ->
          {conn.remote_ip |> :inet.ntoa() |> to_string(), :remote_ip}
      end

    :telemetry.execute([:stacks, :rate_limit, :client_ip], %{count: 1}, %{source: source})

    ip
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

      if limit = System.get_env("RATE_LIMIT_AUTH") do
        Application.put_env(:core, :rate_limit_auth, String.to_integer(limit))
      end

      if limit = System.get_env("RATE_LIMIT_PASSWORD_CHANGE") do
        Application.put_env(:core, :rate_limit_password_change, String.to_integer(limit))
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
