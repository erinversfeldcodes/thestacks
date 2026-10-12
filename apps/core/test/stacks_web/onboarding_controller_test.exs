defmodule StacksWeb.OnboardingControllerTest do
  @moduledoc """
      Tests for:
      - GET  /api/onboarding/status
      - PUT  /api/onboarding/step/:step
  """

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "GET /api/onboarding/status — status" do
    test "returns all steps false for a fresh user", %{conn: conn} do
      user = insert(:user)
      conn = conn |> auth_conn(user) |> get("/api/onboarding/status")

      assert %{
               "steps" => %{
                 "profile" => false,
                 "privacy" => false
               },
               "completed" => false,
               "next_step" => "profile"
             } = json_response(conn, 200)
    end

    test "returns correct next_step for partially completed user", %{conn: conn} do
      user = insert(:user, onboarding_steps: %{"profile" => true})
      conn = conn |> auth_conn(user) |> get("/api/onboarding/status")
      body = json_response(conn, 200)

      assert body["next_step"] == "privacy"
      assert body["steps"]["profile"] == true
      assert body["steps"]["privacy"] == false
    end

    test "returns completed true when all steps done", %{conn: conn} do
      user =
        insert(:user,
          onboarding_steps: %{
            "profile" => true,
            "privacy" => true
          }
        )

      conn = conn |> auth_conn(user) |> get("/api/onboarding/status")
      body = json_response(conn, 200)

      assert body["completed"] == true
      assert body["next_step"] == nil
    end

    test "returns 401 when unauthenticated", %{conn: conn} do
      conn = get(conn, "/api/onboarding/status")
      assert json_response(conn, 401)
    end
  end

  describe "PUT /api/onboarding/step/:step — complete_step" do
    test "marks profile step as complete", %{conn: conn} do
      user = insert(:user)
      conn = conn |> auth_conn(user) |> put("/api/onboarding/step/profile")
      body = json_response(conn, 200)

      assert body["steps"]["profile"] == true
      assert body["next_step"] == "privacy"
    end

    test "age_verification step is rejected as invalid", %{conn: conn} do
      user = insert(:user, onboarding_steps: %{"profile" => true})
      conn = conn |> auth_conn(user) |> put("/api/onboarding/step/age_verification")
      body = json_response(conn, 422)

      assert body["error"] == "invalid_step"
    end

    test "completing final step returns completed true", %{conn: conn} do
      user =
        insert(:user,
          onboarding_steps: %{
            "profile" => true
          }
        )

      conn = conn |> auth_conn(user) |> put("/api/onboarding/step/privacy")
      body = json_response(conn, 200)

      assert body["completed"] == true
      assert body["next_step"] == nil
    end

    test "is idempotent — completing already-done step returns 200", %{conn: conn} do
      user = insert(:user, onboarding_steps: %{"profile" => true})
      conn = conn |> auth_conn(user) |> put("/api/onboarding/step/profile")
      body = json_response(conn, 200)

      assert body["steps"]["profile"] == true
    end

    test "returns 422 for invalid step name", %{conn: conn} do
      user = insert(:user)
      conn = conn |> auth_conn(user) |> put("/api/onboarding/step/invalid_step")
      body = json_response(conn, 422)

      assert body["error"] == "invalid_step"
      assert "profile" in body["valid_steps"]
    end

    test "returns 401 when unauthenticated", %{conn: conn} do
      conn = put(conn, "/api/onboarding/step/profile")
      assert json_response(conn, 401)
    end
  end
end
