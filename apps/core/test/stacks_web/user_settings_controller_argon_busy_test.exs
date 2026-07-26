defmodule StacksWeb.UserSettingsControllerArgonBusyTest do
  @moduledoc """
  Exercises the `{:error, :argon2_busy}` -> 503 mapping in
  `UserSettingsController` for the two endpoints that hash/verify a password
  through `Stacks.Accounts.ArgonPool` (Issue #126, Phase 3, item 6).

  `async: false`: these tests saturate the GLOBAL, singleton ArgonPool and shrink
  its checkout timeout so `ArgonPool.run/1` returns `{:error, :argon2_busy}`
  immediately. They must not run concurrently with any other Argon2-using test —
  ExUnit runs sync modules in isolation, so keep this module `async: false`.
  """

  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts.ArgonPool
  alias Stacks.Accounts.Guardian

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  # Hold every ArgonPool worker and shrink the checkout timeout to 0 so any
  # `ArgonPool.run/1` from the request pipeline times out at once and yields
  # `{:error, :argon2_busy}`. Returns a zero-arg release fn (holders freed,
  # timeout restored). Mirrors the saturation pattern in argon_pool_test.exs.
  defp saturate_argon_pool do
    original_timeout = Application.get_env(:core, :argon2_checkout_timeout_ms)
    Application.put_env(:core, :argon2_checkout_timeout_ms, 0)

    pool_size = Application.get_env(:core, :argon2_pool_size, 2)
    parent = self()

    holders = for _ <- 1..pool_size, do: Task.async(fn -> hold_argon_worker(parent) end)

    for _ <- 1..pool_size, do: assert_receive(:holding, 2_000)

    fn ->
      for t <- holders, do: send(t.pid, :release)
      for t <- holders, do: Task.await(t)

      if original_timeout do
        Application.put_env(:core, :argon2_checkout_timeout_ms, original_timeout)
      else
        Application.delete_env(:core, :argon2_checkout_timeout_ms)
      end
    end
  end

  # Checks out one ArgonPool worker and blocks it until told to `:release`,
  # signalling `parent` once it holds the worker. Extracted from
  # saturate_argon_pool/0 to keep the checkout closure shallow.
  defp hold_argon_worker(parent) do
    NimblePool.checkout!(
      ArgonPool,
      :checkout,
      fn _from, nil ->
        send(parent, :holding)
        await_release()
      end,
      5_000
    )
  end

  defp await_release do
    receive do
      :release -> {nil, nil}
    end
  end

  describe "PUT /api/settings/password when the Argon2 pool is saturated" do
    test "returns 503 service_busy with retry-after: 5", %{conn: conn} do
      user = insert(:user)
      release = saturate_argon_pool()

      try do
        conn =
          conn
          |> auth_conn(user)
          |> put("/api/settings/password", %{
            current_password: "password123",
            new_password: "newpassword456"
          })

        assert %{"error" => "service_busy"} = json_response(conn, 503)
        assert get_resp_header(conn, "retry-after") == ["5"]
      after
        release.()
      end
    end
  end

  describe "PUT /api/settings/profile (email change) when the Argon2 pool is saturated" do
    test "returns 503 service_busy with retry-after: 5", %{conn: conn} do
      # Only the email-change path verifies a password (via ArgonPool), so the
      # payload must carry a genuinely different email plus current_password.
      user = insert(:user, email: "old@example.com")
      release = saturate_argon_pool()

      try do
        conn =
          conn
          |> auth_conn(user)
          |> put("/api/settings/profile", %{
            email: "new@example.com",
            current_password: "password123"
          })

        assert %{"error" => "service_busy"} = json_response(conn, 503)
        assert get_resp_header(conn, "retry-after") == ["5"]
      after
        release.()
      end
    end
  end
end
