defmodule StacksWeb.GuardianJwtDeployedTest do
  @moduledoc """
      LIVE-STACK JWT-at-rest invariant: the fix is a DB trigger forcing
      `guardian_tokens.jwt = NULL`, and the protected asset is the REAL Neon
      DB behind the preview — the local test only proves the trigger on the
      sandbox Postgres. Logs in via the real API, then reads the preview DB
      directly to assert no row holds a raw JWT. Skips locally.
  """

  use ExUnit.Case, async: false

  @moduletag :deployed_only

  @base_url System.get_env("BASE_URL")

  if @base_url in [nil, ""] do
    @moduletag skip: "BASE_URL not set — deployed Fly preview required"
  end

  @dev_email "owner@thestacks.app"
  @dev_password "dev-password-123"

  defp user_id_for_email(conn, email) do
    %Postgrex.Result{rows: rows} =
      Postgrex.query!(conn, "SELECT id::text FROM op.users WHERE email = $1 LIMIT 1", [email])

    case rows do
      [[id]] -> id
      [] -> nil
    end
  end

  defp latest_token_jwt(conn, user_id) do
    %Postgrex.Result{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT jwt
          FROM op.guardian_tokens
         WHERE sub = $1
         ORDER BY inserted_at DESC, exp DESC
         LIMIT 1
        """,
        [user_id]
      )

    case rows do
      [[jwt]] -> {:ok, jwt}
      [] -> :none
    end
  end

  setup do
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
        # `ssl: true` + `ssl_opts:` is the pre-0.20 Postgrex API. 0.22 warns
        # ":ssl_opts is deprecated, pass opts to :ssl instead" and IGNORES it,
        # so the connection is attempted without TLS and Neon refuses it with
        # "ssl not available" — which reads as a server problem, not a client
        # one. These deployed-only tests could not reach Neon at all until this
        # was changed, and nothing noticed because they are excluded by default.
        ssl: [verify: :verify_none]
      )

    on_exit(fn -> if Process.alive?(conn), do: GenServer.stop(conn) end)

    {:ok, conn: conn}
  end

  defp latest_token_sst(conn, user_id) do
    %Postgrex.Result{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT claims->>'sst'
          FROM op.guardian_tokens
         WHERE sub = $1
         ORDER BY inserted_at DESC, exp DESC
         LIMIT 1
        """,
        [user_id]
      )

    case rows do
      [[sst]] -> {:ok, sst}
      [] -> :none
    end
  end

  describe "raw JWT store on the live Fly + Neon stack" do
    @tag timeout: 120_000
    test "after a real login, the persisted guardian_tokens row holds no bearer token", %{
      conn: conn
    } do
      base_url = @base_url

      resp =
        Req.post!("#{base_url}/api/auth/login",
          json: %{email: @dev_email, password: @dev_password},
          receive_timeout: 60_000,
          retry: :transient,
          max_retries: 8,
          retry_delay: fn attempt ->
            min(:timer.seconds(2) * (attempt + 1), :timer.seconds(10))
          end
        )

      assert resp.status == 200,
             "expected 200 from login through preview, got #{resp.status}: #{inspect(resp.body)}"

      token = resp.body["token"]
      assert is_binary(token) and token != "", "login response carried no token"

      user_id = user_id_for_email(conn, @dev_email)
      assert user_id, "seeded owner #{@dev_email} not found in preview op.users"

      case latest_token_jwt(conn, user_id) do
        {:ok, jwt} ->
          assert jwt == nil,
                 "op.guardian_tokens.jwt held a bearer token on the live stack (#{inspect(jwt)}) — a DB dump yields a replayable session"

        :none ->
          flunk(
            "no op.guardian_tokens row found for #{@dev_email} (#{user_id}) after a successful login"
          )
      end
    end

    @tag timeout: 120_000
    test "after a real login, the persisted claims carry a non-null session-start anchor (sst)",
         %{
           conn: conn
         } do
      base_url = @base_url

      resp =
        Req.post!("#{base_url}/api/auth/login",
          json: %{email: @dev_email, password: @dev_password},
          receive_timeout: 60_000,
          retry: :transient,
          max_retries: 8,
          retry_delay: fn attempt ->
            min(:timer.seconds(2) * (attempt + 1), :timer.seconds(10))
          end
        )

      assert resp.status == 200,
             "expected 200 from login through preview, got #{resp.status}: #{inspect(resp.body)}"

      user_id = user_id_for_email(conn, @dev_email)
      assert user_id, "seeded owner #{@dev_email} not found in preview op.users"

      case latest_token_sst(conn, user_id) do
        {:ok, sst} ->
          assert sst not in [nil, ""],
                 "op.guardian_tokens.claims carried no sst on the live stack — the absolute session cap cannot be anchored"

          assert {n, ""} = Integer.parse(sst)
          assert n > 0, "persisted sst was not a positive unix timestamp: #{inspect(sst)}"

        :none ->
          flunk(
            "no op.guardian_tokens row found for #{@dev_email} (#{user_id}) after a successful login"
          )
      end
    end
  end
end
