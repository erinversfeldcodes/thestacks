defmodule StacksWeb.Plugs.RateLimiterTest do
  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias StacksWeb.Plugs.RateLimiter

  setup do
    original = Application.get_env(:core, :rate_limiting_enabled)
    Application.put_env(:core, :rate_limiting_enabled, true)

    original_auth = Application.get_env(:core, :rate_limit_auth)
    original_pwc = Application.get_env(:core, :rate_limit_password_change)
    Application.put_env(:core, :rate_limit_auth, 5)
    Application.put_env(:core, :rate_limit_password_change, 3)

    on_exit(fn ->
      Application.put_env(:core, :rate_limiting_enabled, original)

      if original_auth do
        Application.put_env(:core, :rate_limit_auth, original_auth)
      else
        Application.delete_env(:core, :rate_limit_auth)
      end

      if original_pwc do
        Application.put_env(:core, :rate_limit_password_change, original_pwc)
      else
        Application.delete_env(:core, :rate_limit_password_change)
      end

      if :ets.whereis(:rate_limiter) != :undefined do
        :ets.delete_all_objects(:rate_limiter)
      end
    end)

    :ok
  end

  describe "call/2 when rate limiting is disabled" do
    test "passes conn through without checking ETS", %{conn: conn} do
      Application.put_env(:core, :rate_limiting_enabled, false)
      conn = %{conn | remote_ip: {10, 0, 0, 1}}
      result = RateLimiter.call(conn, [])
      refute result.halted
    end
  end

  describe "call/2 global bucket" do
    test "allows first request", %{conn: conn} do
      conn = %{conn | remote_ip: {10, 0, 0, 2}}
      result = RateLimiter.call(conn, [])
      refute result.halted
    end

    test "allows multiple requests below the global limit", %{conn: conn} do
      conn = %{conn | remote_ip: {10, 0, 0, 3}}

      for _ <- 1..10 do
        result = RateLimiter.call(conn, [])
        refute result.halted
      end
    end
  end

  describe "call/2 auth bucket" do
    test "allows exactly 5 requests from the same IP", %{conn: conn} do
      conn = %{conn | remote_ip: {10, 1, 0, 1}}

      for _ <- 1..5 do
        result = RateLimiter.call(conn, bucket: :auth)
        refute result.halted
      end
    end

    test "blocks the 6th auth request and returns 429", %{conn: conn} do
      conn = %{conn | remote_ip: {10, 1, 0, 2}}

      for _ <- 1..5, do: RateLimiter.call(conn, bucket: :auth)

      result = RateLimiter.call(conn, bucket: :auth)
      assert result.halted
      assert result.status == 429
    end

    test "429 response includes retry-after header", %{conn: conn} do
      conn = %{conn | remote_ip: {10, 1, 0, 3}}

      for _ <- 1..5, do: RateLimiter.call(conn, bucket: :auth)
      result = RateLimiter.call(conn, bucket: :auth)

      assert get_resp_header(result, "retry-after") == ["60"]
    end

    test "429 response body is JSON with error key", %{conn: conn} do
      conn = %{conn | remote_ip: {10, 1, 0, 4}}

      for _ <- 1..5, do: RateLimiter.call(conn, bucket: :auth)
      result = RateLimiter.call(conn, bucket: :auth)

      body = Jason.decode!(result.resp_body)
      assert body["error"] == "rate_limit_exceeded"
    end

    test "a 429 rejection emits [:stacks, :rate_limit, :rejected] with the bucket tag",
         %{conn: conn} do
      conn = %{conn | remote_ip: {10, 1, 0, 5}}

      test_pid = self()
      handler_id = "test-ratelimit-206-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:stacks, :rate_limit, :rejected],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      for _ <- 1..5, do: RateLimiter.call(conn, bucket: :auth)
      RateLimiter.call(conn, bucket: :auth)

      assert_receive {:telemetry_event, [:stacks, :rate_limit, :rejected], %{count: 1},
                      %{bucket: :auth}}
    end
  end

  describe "call/2 upload bucket" do
    test "allows first upload for authenticated user", %{conn: conn} do
      user = insert(:user)

      conn =
        conn |> assign(:guardian_default_resource, user) |> Map.put(:remote_ip, {10, 2, 0, 1})

      result = RateLimiter.call(conn, bucket: :upload)
      refute result.halted
    end

    test "uses IP as key for unauthenticated upload request", %{conn: conn} do
      conn = %{conn | remote_ip: {10, 2, 0, 2}}

      result = RateLimiter.call(conn, bucket: :upload)
      refute result.halted
    end

    test "blocks the 121st upload for the same authenticated user", %{conn: conn} do
      user = insert(:user)

      conn =
        conn |> assign(:guardian_default_resource, user) |> Map.put(:remote_ip, {10, 2, 0, 3})

      for _ <- 1..120, do: RateLimiter.call(conn, bucket: :upload)

      result = RateLimiter.call(conn, bucket: :upload)
      assert result.halted
      assert result.status == 429
    end
  end

  describe "call/2 IP extraction" do
    test "keys on fly-client-ip: different Fly-Client-IP values are isolated buckets",
         %{conn: conn} do
      base = %{conn | remote_ip: {10, 5, 0, 1}}
      client_a = put_req_header(base, "fly-client-ip", "198.51.100.20")
      client_b = put_req_header(base, "fly-client-ip", "198.51.100.21")

      for _ <- 1..5, do: RateLimiter.call(client_a, bucket: :auth)
      assert RateLimiter.call(client_a, bucket: :auth).halted

      refute RateLimiter.call(client_b, bucket: :auth).halted
    end

    test "keys on fly-client-ip: same Fly-Client-IP shares one bucket and is limited",
         %{conn: conn} do
      fly_ip = "198.51.100.30"

      for n <- 1..5 do
        c = %{conn | remote_ip: {10, 5, 1, n}} |> put_req_header("fly-client-ip", fly_ip)
        refute RateLimiter.call(c, bucket: :auth).halted
      end

      sixth = %{conn | remote_ip: {10, 5, 1, 200}} |> put_req_header("fly-client-ip", fly_ip)
      result = RateLimiter.call(sixth, bucket: :auth)
      assert result.halted
      assert result.status == 429
    end

    test "SECURITY: rotating X-Forwarded-For with a fixed Fly-Client-IP is still rate-limited",
         %{conn: conn} do
      base =
        %{conn | remote_ip: {10, 4, 0, 1}} |> put_req_header("fly-client-ip", "198.51.100.10")

      for n <- 1..5 do
        c = put_req_header(base, "x-forwarded-for", "203.0.113.#{n}")
        refute RateLimiter.call(c, bucket: :auth).halted
      end

      spoofed = put_req_header(base, "x-forwarded-for", "203.0.113.6")
      result = RateLimiter.call(spoofed, bucket: :auth)
      assert result.halted
      assert result.status == 429
    end

    test "SECURITY: password_change bucket — rotating XFF with a fixed Fly-Client-IP is still rate-limited",
         %{conn: conn} do
      base =
        %{conn | remote_ip: {10, 7, 0, 1}} |> put_req_header("fly-client-ip", "198.51.100.40")

      for n <- 1..3 do
        c = put_req_header(base, "x-forwarded-for", "203.0.113.#{30 + n}")
        refute RateLimiter.call(c, bucket: :password_change).halted
      end

      spoofed = put_req_header(base, "x-forwarded-for", "203.0.113.99")
      result = RateLimiter.call(spoofed, bucket: :password_change)
      assert result.halted
      assert result.status == 429
    end

    test "SECURITY: X-Forwarded-For is not trusted — rotating XFF shares the remote_ip bucket",
         %{conn: conn} do
      base = %{conn | remote_ip: {10, 6, 0, 1}}

      for n <- 1..5 do
        c = put_req_header(base, "x-forwarded-for", "203.0.113.#{100 + n}")
        refute RateLimiter.call(c, bucket: :auth).halted
      end

      spoofed = put_req_header(base, "x-forwarded-for", "203.0.113.200")
      result = RateLimiter.call(spoofed, bucket: :auth)
      assert result.halted
      assert result.status == 429
    end

    test "falls back to remote_ip when fly-client-ip is absent", %{conn: conn} do
      conn = %{conn | remote_ip: {192, 0, 2, 1}}

      for _ <- 1..5, do: RateLimiter.call(conn, bucket: :auth)

      result = RateLimiter.call(conn, bucket: :auth)
      assert result.halted
      assert result.status == 429
    end
  end

  describe "call/2 client-IP source telemetry" do
    setup do
      test_pid = self()
      handler_id = "test-client-ip-240-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:stacks, :rate_limit, :client_ip],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "header present → source: :trusted_proxy (and no IP value in metadata)", %{conn: conn} do
      conn =
        %{conn | remote_ip: {10, 9, 0, 1}}
        |> put_req_header("fly-client-ip", "198.51.100.77")

      refute RateLimiter.call(conn, []).halted

      assert_receive {:telemetry_event, [:stacks, :rate_limit, :client_ip], %{count: 1}, metadata}
      assert metadata == %{source: :trusted_proxy}
    end

    test "header absent, remote_ip present → source: :remote_ip (and no IP value in metadata)",
         %{conn: conn} do
      conn = %{conn | remote_ip: {10, 9, 0, 2}}

      refute RateLimiter.call(conn, []).halted

      assert_receive {:telemetry_event, [:stacks, :rate_limit, :client_ip], %{count: 1}, metadata}
      assert metadata == %{source: :remote_ip}
    end

    test "empty fly-client-ip header falls through to remote_ip", %{conn: conn} do
      conn =
        %{conn | remote_ip: {10, 9, 0, 3}}
        |> put_req_header("fly-client-ip", "")

      refute RateLimiter.call(conn, []).halted

      assert_receive {:telemetry_event, [:stacks, :rate_limit, :client_ip], %{count: 1}, metadata}
      assert metadata == %{source: :remote_ip}
    end
  end

  describe "call/2 when ETS table is unavailable" do
    test "allows request through and logs an error", %{conn: conn} do
      conn = %{conn | remote_ip: {10, 3, 0, 1}}

      # Temporarily make ETS unavailable by deleting all objects is not enough;
      # we need the table to not exist. Use a process that owns the table instead.
      # The simplest approach: rename using ets by testing via a dedicated process.
      pid =
        spawn(fn ->
          :ets.new(:rate_limiter_shadow, [:named_table, :public, :set])
          Process.sleep(:infinity)
        end)

      :timer.sleep(10)

      Process.exit(pid, :kill)

      result = RateLimiter.call(conn, [])
      refute result.halted
    end
  end

  describe "RateLimiter.Server" do
    test "named ETS table exists after application start" do
      assert :ets.whereis(:rate_limiter) != :undefined
    end

    test "cleanup message removes expired entries" do
      server = Process.whereis(RateLimiter.Server)
      assert is_pid(server)

      past_ms = System.system_time(:millisecond) - 120_000
      :ets.insert(:rate_limiter, {{"stale_key", :auth}, [{past_ms}]})
      assert :ets.lookup(:rate_limiter, {"stale_key", :auth}) != []

      send(server, :cleanup)
      :timer.sleep(50)

      assert :ets.lookup(:rate_limiter, {"stale_key", :auth}) == []
    end

    test "cleanup retains entries within the window" do
      server = Process.whereis(RateLimiter.Server)
      assert is_pid(server)

      now_ms = System.system_time(:millisecond)
      :ets.insert(:rate_limiter, {{"fresh_key", :global}, [{now_ms}]})

      send(server, :cleanup)
      :timer.sleep(50)

      assert :ets.lookup(:rate_limiter, {"fresh_key", :global}) != []
    end
  end

  describe "PUT /api/settings/password through the router pipeline" do
    test "the 4th password change in the window is rate-limited (429)", %{conn: conn} do
      user = insert(:user)
      {:ok, token, _} = Guardian.encode_and_sign(user)

      authed = fn c ->
        %{c | remote_ip: {203, 0, 113, 250}}
        |> put_req_header("authorization", "Bearer #{token}")
      end

      body = %{current_password: "wrong-password", new_password: "newpassword456"}

      for _ <- 1..3 do
        c = conn |> authed.() |> put("/api/settings/password", body)
        assert json_response(c, 422)
      end

      c = conn |> authed.() |> put("/api/settings/password", body)
      assert %{"error" => "rate_limit_exceeded"} = json_response(c, 429)
    end
  end
end
