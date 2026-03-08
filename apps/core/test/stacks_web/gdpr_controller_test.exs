defmodule StacksWeb.GDPRControllerTest do
  @moduledoc """
  Tests for GDPR routes:
  - POST   /api/gdpr/export
  - DELETE /api/gdpr/account
  - POST   /api/gdpr/consent

  Oban is in :manual testing mode (configured in test.exs), so jobs are asserted
  via Oban.Testing helpers without actually being executed.
  """

  use CoreWeb.ConnCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Workers.{AccountDeletionJob, DataExportJob}

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  # ---------------------------------------------------------------------------
  # POST /api/gdpr/export
  # ---------------------------------------------------------------------------

  describe "POST /api/gdpr/export" do
    test "returns 202 and enqueues DataExportJob", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/gdpr/export")

      assert %{"status" => "accepted"} = json_response(conn, 202)
      assert_enqueued(worker: DataExportJob, args: %{"user_id" => user.id})
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = post(conn, "/api/gdpr/export")
      assert json_response(conn, 401)
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE /api/gdpr/account
  # ---------------------------------------------------------------------------

  describe "DELETE /api/gdpr/account" do
    test "returns 202 and enqueues AccountDeletionJob", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> delete("/api/gdpr/account")

      assert %{"status" => "accepted"} = json_response(conn, 202)
      assert_enqueued(worker: AccountDeletionJob, args: %{"user_id" => user.id})
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = delete(conn, "/api/gdpr/account")
      assert json_response(conn, 401)
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/gdpr/consent
  # ---------------------------------------------------------------------------

  describe "POST /api/gdpr/consent" do
    test "returns 200 and grants consent when consent: true", %{conn: conn} do
      user = insert(:user, consent_analytics: false)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/gdpr/consent", %{consent: true})

      assert %{"consent_analytics" => true} = json_response(conn, 200)
    end

    test "returns 200 and revokes consent when consent: false", %{conn: conn} do
      user = insert(:user, consent_analytics: true)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/gdpr/consent", %{consent: false})

      assert %{"consent_analytics" => false} = json_response(conn, 200)
    end

    test "returns 422 when consent has an invalid value", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/gdpr/consent", %{consent: "maybe"})

      assert %{"error" => _} = json_response(conn, 422)
    end

    test "returns 422 when consent parameter is missing", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/gdpr/consent", %{})

      assert %{"error" => "consent parameter is required"} = json_response(conn, 422)
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = post(conn, "/api/gdpr/consent", %{consent: true})
      assert json_response(conn, 401)
    end
  end
end
