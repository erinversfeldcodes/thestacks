defmodule StacksWeb.Plugs.RateLimiter do
  @moduledoc """
      ETS-backed sliding-window rate limiter. Buckets: `:auth` 60/60s per IP;
      `:password_change` 20/60s per IP; `:public` 200/60s per IP; `:admin`
      30/60s per IP; `:e2e_helper` 10/60s per IP; `:upload` 120/60s per user;
      `:social` 20/60s per user; `:feedback` 10/60s per user.

      ⛔ There is no default bucket, and no limit that applies to everything.
      `init/1` refuses a plug site that names no `:bucket`, or names one with no
      limit, so a new pipeline cannot inherit another's budget by omitting it.
      The default removed here was a `global` 1000/60s: all eight plug sites
      passed an explicit bucket, so it governed no request in this limiter's
      lifetime while this docstring advertised it first. A route is limited only
      by opting into one of the `rate_limit_*` pipelines; `:api` and `:spa`
      carry none, so there is no floor underneath the rest.

      Overrides, and there are two mechanisms rather than one:
      `RATE_LIMIT_AUTH`, `RATE_LIMIT_PUBLIC` and `RATE_LIMIT_E2E_HELPER` are
      applied in the umbrella's ROOT `config/runtime.exs` for every non-test
      environment, and `RATE_LIMIT_AUTH` plus `RATE_LIMIT_PASSWORD_CHANGE` are
      applied again by `Server.init/1` at boot. ⚠️ `:admin` and `:feedback`
      read an `Application` key that nothing writes, so the figures above are
      the only ones they ever take — a reader with no writer, which is the
      mirror image of the bucket this docstring used to advertise.

      ⚠️ `apps/core/config/` is NOT the whole config tree. The root
      `config/` is what a release evaluates, and reading only the inner one
      says these overrides are unwired when they are wired.

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
  @auth_limit 60
  @upload_limit 120
  @password_change_limit 20
  @social_limit 20
  @public_limit 200
  @admin_limit 30
  @e2e_helper_limit 10
  @feedback_limit 10

  # ⛔ The bucket is resolved here, at the plug site, not per request. `init/1`
  # runs at compile time under the default plug init mode, so a pipeline that
  # names no bucket — or names one with no limit — cannot be built, rather than
  # 500ing on the first request that reaches it. `get_limit/1` is the single
  # source of truth for which buckets exist; calling it here is the whole
  # validation, so the two cannot disagree.
  def init(opts) do
    bucket =
      Keyword.get(opts, :bucket) ||
        raise ArgumentError, """
        StacksWeb.Plugs.RateLimiter requires an explicit `bucket:`.

        There is no default: a bucket omitted here used to mean a 1000/60s
        budget that nothing else shared, which read as a floor and was not one.
        Name the bucket this pipeline should spend from, and give it a
        `get_limit/1` clause if it does not have one yet.
        """

    _ = get_limit(bucket)
    opts
  end

  def call(conn, opts) do
    if Application.get_env(:core, :rate_limiting_enabled, true) do
      do_rate_check(conn, opts)
    else
      conn
    end
  end

  defp do_rate_check(conn, opts) do
    bucket = Keyword.fetch!(opts, :bucket)
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

  defp get_limit(bucket) do
    raise ArgumentError,
          "StacksWeb.Plugs.RateLimiter has no limit for bucket #{inspect(bucket)}. " <>
            "Add a get_limit/1 clause for it — there is deliberately no catch-all, " <>
            "because the catch-all that used to be here answered for every bucket " <>
            "nobody had defined and made the mistake invisible."
  end

  # ⛔ `Guardian.Plug.current_resource/1`, NOT `conn.assigns[:guardian_default_resource]`.
  #
  # Guardian keeps its pipeline state in `conn.private`, so reading the same name
  # out of `conn.assigns` returned `nil` on EVERY request and these three buckets
  # silently fell back to the IP — against a moduledoc two screens up that says
  # "per user" for all three. Signed-in readers behind one NAT or corporate proxy
  # therefore shared a single budget: ten feedback submissions a minute, twenty
  # social actions and a hundred and twenty uploads between all of them.
  #
  # ⚠️ The tests agreed with the bug because they built the world the code
  # expected — `assign(:guardian_default_resource, user)` is not what the real
  # pipeline does, so "blocks the 121st upload for the same authenticated user"
  # passed while keyed on the fixed IP those conns also carried. The assertion
  # that finds this is two DIFFERENT users on ONE IP, which is below.
  #
  # The IP fallback stays for an unauthenticated request. All three of these
  # routes are authenticated, so it is defence rather than a path.
  defp get_key(conn, bucket) when bucket in [:upload, :social, :feedback] do
    case Guardian.Plug.current_resource(conn) do
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
    {ip, source} = StacksWeb.ClientIP.get_with_source(conn)

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
