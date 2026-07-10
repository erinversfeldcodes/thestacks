defmodule StacksWeb.AuditIpDeployedTest do
  @moduledoc """
  LIVE-STACK audit-provenance validation (Issue #176, B2).

  The audit-log IP is stamped from the TRUSTED `fly-client-ip` header, which Fly
  injects/overwrites at its edge — a real client cannot set it. The spoofable
  `x-forwarded-for` must NEVER be recorded as provenance.

  Local unit/integration tests (`auth_controller_test.exs`) set `fly-client-ip`
  and `x-forwarded-for` by hand, which is impossible on a real Fly deployment.
  This test closes that gap: it drives the PUBLIC register endpoint through the
  real Fly-fronted preview carrying a spoofed `x-forwarded-for`, then reads the
  durable side effect — the `audit.audit_log` row — from the preview DB and
  asserts the spoofed value was NOT trusted.

  Runs only under the deployed target (`@moduletag :deployed_only`, excluded by
  test_helper.exs). Invoke via:

      TEST_TARGET=deployed BASE_URL=https://<preview>.fly.dev \\
        DATABASE_URL=postgres://…<preview neon> \\
        mix test --only deployed_only test/stacks_web/audit_ip_deployed_test.exs

  NOTE: `Core.Repo` is NOT usable here. `apps/core/config/test.exs` hardcodes
  Core.Repo to `hostname: "localhost"` / `stacks_test`, and there is no deployed
  runtime override — so `DATABASE_URL=<preview>` does NOT repoint Core.Repo, and
  a Repo.query would read the local test DB (where the live-registered user does
  not exist). Instead we open a DIRECT Postgrex connection straight to
  `DATABASE_URL` (the preview Neon URL the runner passes) and read the row the
  live app actually committed there.

  ONE register request → does not meaningfully load the per-IP `:auth` bucket
  (well under the 60/60s limit), so it is safe to run alongside other deployed
  tests. The saturating flood lives in the Playwright `ratelimit` project.
  """

  use ExUnit.Case, async: false

  @moduletag :deployed_only

  # BASE_URL is resolved when this test file loads (at `mix test` start, after
  # the env is in place). Without a preview target there is nothing to drive, so
  # skip the whole module rather than fail — this keeps a bare
  # `--only deployed_only` run without BASE_URL inert instead of red.
  @base_url System.get_env("BASE_URL")

  if @base_url in [nil, ""] do
    @moduletag skip: "BASE_URL not set — deployed Fly preview required"
  end

  # A spoofed, attacker-controlled forwarded-for. On the real stack Fly rewrites
  # `fly-client-ip` with the true client address, so this XFF must be ignored
  # for provenance. Hashed the same way Audit.hash_ip/1 does (sha256, hex-lower).
  @spoofed_xff "203.0.113.99"

  defp sha256_hex(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  # Reads the ip_address of the most recent audit.audit_log row for a user +
  # action via raw SQL on a DIRECT Postgrex connection to the preview DB,
  # mirroring latest_audit_row/1 in auth_controller_test.exs (independent of the
  # proto-generated Ecto schema shape). user_id is a text UUID; we compare the
  # column cast to text (user_id::text = $1) so no 16-byte UUID binary encoding
  # is needed on the Postgrex param.
  defp latest_audit_ip(conn, user_id, action) do
    %Postgrex.Result{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT ip_address
          FROM audit.audit_log
         WHERE user_id::text = $1
           AND action = $2
         ORDER BY occurred_at DESC
         LIMIT 1
        """,
        [user_id, action]
      )

    case rows do
      [[ip]] -> ip
      [] -> nil
    end
  end

  defp user_id_for_email(conn, email) do
    %Postgrex.Result{rows: rows} =
      Postgrex.query!(conn, "SELECT id::text FROM op.users WHERE email = $1 LIMIT 1", [email])

    case rows do
      [[id]] -> id
      [] -> nil
    end
  end

  setup do
    # Core.Repo is hardcoded to localhost/stacks_test (config/test.exs) with no
    # deployed override, so it CANNOT read the preview DB. Open a direct Postgrex
    # connection to the preview Neon URL the runner passes in DATABASE_URL, which
    # sees the row the live app committed over HTTP. Neon requires SSL;
    # verify_none skips CA-bundle fuss for the preview cert (acceptable in test).
    db_url = System.get_env("DATABASE_URL")
    uri = URI.parse(db_url)
    [user, pass] = String.split(uri.userinfo || "", ":", parts: 2)

    database =
      uri.path |> String.trim_leading("/") |> String.split("?") |> hd()

    {:ok, conn} =
      Postgrex.start_link(
        hostname: uri.host,
        port: uri.port || 5432,
        username: user,
        password: pass,
        database: database,
        ssl: true,
        ssl_opts: [verify: :verify_none]
      )

    on_exit(fn -> if Process.alive?(conn), do: GenServer.stop(conn) end)

    {:ok, conn: conn}
  end

  describe "audit provenance IP on the live Fly stack" do
    @tag timeout: 90_000
    test "a spoofed X-Forwarded-For on register is NOT recorded as the audit IP", %{conn: conn} do
      base_url = @base_url

      # Fresh, unique account so the register succeeds and writes exactly one
      # `user.registered` audit row we can pinpoint.
      email =
        "audit-xff-#{System.system_time(:millisecond)}-#{:rand.uniform(1_000_000)}@ratelimit.test"

      # Fly auto-stops idle preview machines (auto_stop_machines, Issue #175), so
      # the first request can hit a cold machine and 502/503/504 while it wakes.
      # A real user retries and succeeds — so does this test: retry: :transient
      # replays the same register on connection errors + 408/429/5xx, with a
      # 2s→10s backoff over 8 attempts to cover the cold-start window.
      resp =
        Req.post!("#{base_url}/api/auth/register",
          json: %{email: email, password: "password123"},
          headers: [{"x-forwarded-for", @spoofed_xff}],
          receive_timeout: 60_000,
          retry: :transient,
          max_retries: 8,
          retry_delay: fn attempt ->
            min(:timer.seconds(2) * (attempt + 1), :timer.seconds(10))
          end
        )

      # Registration must have succeeded through the real stack (201).
      assert resp.status == 201,
             "expected 201 from register through preview, got #{resp.status}: #{inspect(resp.body)}"

      # The register response body carries no user id, so resolve it from the
      # unique email against the preview DB.
      user_id = user_id_for_email(conn, email)
      assert user_id, "registered user #{email} not found in preview op.users"

      recorded_ip = latest_audit_ip(conn, user_id, "user.registered")

      assert recorded_ip,
             "no user.registered audit row found for #{email} (#{user_id})"

      # THE SECURITY ASSERTION: the spoofed XFF must not be the provenance IP.
      # We can't know the exact Fly-injected client IP to assert the positive,
      # but we can prove the spoof was rejected: the recorded (hashed) IP is not
      # sha256("203.0.113.99").
      refute recorded_ip == sha256_hex(@spoofed_xff),
             "spoofed X-Forwarded-For #{@spoofed_xff} was trusted as the audit provenance IP"
    end
  end
end
