defmodule StacksWeb.GuardianJwtDeployedTest do
  @moduledoc """
  LIVE-STACK JWT-at-rest invariant (Issue #174).

  Why live-stack (not just the local integration test): the fix is a DB-level
  `BEFORE INSERT OR UPDATE` trigger on `op.guardian_tokens` that forces
  `NEW.jwt = NULL`. The local test proves the trigger fires on the local Postgres
  used by the test sandbox, but the *actual* protected asset is the raw JWT store
  on the real Neon topology behind the Fly-fronted preview. Playwright cannot read
  the DB, and the local test uses local Postgres — only a direct read of the
  preview Neon DB after a real login through the real stack proves the trigger is
  actually installed there and holds when the app persists a token over HTTP.

  This drives the PUBLIC login endpoint the way a user does (the seeded owner
  account, the same creds the E2E harness uses — see e2e/tests/helpers.ts:
  owner@thestacks.app / dev-password-123), then reads the durable side effect: the
  `op.guardian_tokens` row(s) for that user, asserting `jwt IS NULL`.

  Runs only under the deployed target (`@moduletag :deployed_only`, excluded by
  test_helper.exs). Needs the preview DATABASE_URL + BASE_URL. Invoke via:

      TEST_TARGET=deployed BASE_URL=https://<preview>.fly.dev \\
        DATABASE_URL=postgres://…<preview neon> \\
        mix test --only deployed_only test/stacks_web/guardian_jwt_deployed_test.exs

  NOTE: `Core.Repo` is NOT usable here. `apps/core/config/test.exs` hardcodes
  Core.Repo to `localhost/stacks_test` with no deployed override, so
  `DATABASE_URL=<preview>` does NOT repoint it — a Repo.query would read the local
  test DB. We open a DIRECT `Postgrex` connection to the preview `DATABASE_URL`
  (the URL the runner passes) and read the row the live app actually committed.
  """

  use ExUnit.Case, async: false

  @moduletag :deployed_only

  # BASE_URL is resolved when the file loads (at `mix test` start, after the env
  # is in place). Without a preview target there is nothing to drive, so skip the
  # whole module rather than fail — a bare `--only deployed_only` run without
  # BASE_URL stays inert instead of red.
  @base_url System.get_env("BASE_URL")

  if @base_url in [nil, ""] do
    @moduletag skip: "BASE_URL not set — deployed Fly preview required"
  end

  # The seeded owner account the E2E harness authenticates with (helpers.ts).
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

  # Reads the jwt of the most-recent guardian_tokens row for a user. `sub` is the
  # user id stored as text (subject_for_token/2 does to_string(user.id)), so we
  # compare it directly to the text UUID — no uuid binary encoding on the param.
  # Returns {:ok, jwt} for the newest row, or :none when the user has no rows.
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

  # Reads the persisted "sst" (session-start anchor) from the newest
  # guardian_tokens row for a user, extracted as text via the jsonb `->>`
  # operator so we do not depend on a Postgrex jsonb decoder being configured on
  # this bare direct connection. Returns {:ok, sst_text}, {:ok, nil} when the
  # key is absent/null, or :none when the user has no rows.
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

      # Log in through the real stack the way the E2E harness does. Fly auto-stops
      # idle preview machines (Issue #175), so the first request can 502/503/504
      # while a cold machine wakes. A real user retries and succeeds — so does this
      # test: retry: :transient replays the login on connection errors + 408/429/5xx
      # with a 2s→10s backoff over 8 attempts to cover the cold-start window.
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

      # The login issued a token → a fresh op.guardian_tokens row was persisted.
      token = resp.body["token"]
      assert is_binary(token) and token != "", "login response carried no token"

      user_id = user_id_for_email(conn, @dev_email)
      assert user_id, "seeded owner #{@dev_email} not found in preview op.users"

      case latest_token_jwt(conn, user_id) do
        {:ok, jwt} ->
          # THE SECURITY ASSERTION: the tracked session row must not contain a
          # replayable bearer token on the real Neon DB.
          assert jwt == nil,
                 "op.guardian_tokens.jwt held a bearer token on the live stack (#{inspect(jwt)}) — a DB dump yields a replayable session"

        :none ->
          flunk(
            "no op.guardian_tokens row found for #{@dev_email} (#{user_id}) after a successful login"
          )
      end
    end

    # Issue #179, Phase 1 live invariant: the absolute-cap anchor must actually
    # be persisted on the real stack. guardian_db writes the FULL claims map to
    # op.guardian_tokens.claims (jsonb), so after a real login through the
    # preview the persisted claims must carry a non-null integer "sst". We do NOT
    # fast-forward 7 days live — the unit tests cover the past-cap 401; this test
    # only proves the anchor reaches the durable store.
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
          # THE CAP-ANCHOR INVARIANT: the persisted session row must carry a
          # non-null session-start anchor so the absolute 7-day cap can be
          # enforced from the session's original issue across rotations.
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
