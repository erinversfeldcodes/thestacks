defmodule StacksWeb.ConfigControllerTest do
  @moduledoc """
    Tests for GET /api/config — the public frontend feature-flag channel (ADR-020).

    `async: false` because the age-gating flag test toggles the process-global
    `:age_gating_enabled` Application env and restores it.
  """

  use CoreWeb.ConnCase, async: false

  describe "GET /api/config" do
    test "returns 200 without authentication (public endpoint)", %{conn: conn} do
      conn = get(conn, "/api/config")
      assert %{"ageGatingEnabled" => _} = json_response(conn, 200)
    end

    test "reflects ageGatingEnabled = true (test-env default)", %{conn: conn} do
      conn = get(conn, "/api/config")

      assert json_response(conn, 200) == %{
               "ageGatingEnabled" => true,
               "inviteOnly" => false
             }
    end

    test "reflects inviteOnly = true when the closed-beta gate is on", %{conn: conn} do
      original = Application.get_env(:core, :invite_only_registration)
      Application.put_env(:core, :invite_only_registration, true)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:core, :invite_only_registration)
          value -> Application.put_env(:core, :invite_only_registration, value)
        end
      end)

      conn = get(conn, "/api/config")
      assert %{"inviteOnly" => true} = json_response(conn, 200)
    end

    test "reflects ageGatingEnabled = false when the flag is off (production posture)", %{
      conn: conn
    } do
      original = Application.get_env(:core, :age_gating_enabled)
      Application.put_env(:core, :age_gating_enabled, false)
      on_exit(fn -> Application.put_env(:core, :age_gating_enabled, original) end)

      conn = get(conn, "/api/config")

      assert json_response(conn, 200) == %{
               "ageGatingEnabled" => false,
               "inviteOnly" => false
             }
    end
  end
end
