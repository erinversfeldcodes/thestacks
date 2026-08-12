defmodule StacksWeb.GDPRControllerTest do
  @moduledoc """
      Tests for GDPR routes:
      - POST   /api/gdpr/export
      - DELETE /api/gdpr/account
      - POST   /api/gdpr/consent

      Oban is in:manual testing mode (configured in test.exs), so jobs are asserted
      via Oban.Testing helpers without actually being executed.
  """

  use CoreWeb.ConnCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Workers.{AccountDeletionJob, DataExportJob, WritingAssistantDataPurgeWorker}

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

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

    test "writes a user.deletion_requested audit row for the acting user, independent of the job",
         %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> delete("/api/gdpr/account")

      assert %{"status" => "accepted"} = json_response(conn, 202)

      row =
        Core.Repo.one(
          from(a in "audit_log",
            where: a.action == "user.deletion_requested",
            select: %{
              user_id: a.user_id,
              resource_type: a.resource_type,
              resource_id: a.resource_id
            }
          ),
          prefix: "audit"
        )

      assert row, "expected a user.deletion_requested audit row to be written by the controller"
      assert row.user_id == Ecto.UUID.dump!(user.id)
      assert row.resource_type == "user"
      assert row.resource_id == Ecto.UUID.dump!(user.id)

      assert_enqueued(worker: AccountDeletionJob, args: %{"user_id" => user.id})
    end

    test "returns 401 when not authenticated", %{conn: conn} do
      conn = delete(conn, "/api/gdpr/account")
      assert json_response(conn, 401)
    end
  end

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

  describe "POST /api/gdpr/consent — writing_assistant feature" do
    test "grants writing_assistant consent and returns the flag + timestamp", %{conn: conn} do
      user = insert(:user, consent_writing_assistant: false)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/gdpr/consent", %{consent: true, type: "writing_assistant"})

      body = json_response(conn, 200)
      assert body["consent_writing_assistant"] == true
      assert body["consent_writing_assistant_at"] != nil
    end

    test "revoking writing_assistant consent returns 200 and enqueues the purge worker",
         %{conn: conn} do
      user = insert(:user, consent_writing_assistant: true)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/gdpr/consent", %{consent: false, type: "writing_assistant"})

      assert %{"consent_writing_assistant" => false} = json_response(conn, 200)

      assert_enqueued(
        worker: WritingAssistantDataPurgeWorker,
        args: %{"user_id" => user.id}
      )
    end

    test "granting writing_assistant consent does NOT enqueue the purge worker", %{conn: conn} do
      user = insert(:user, consent_writing_assistant: false)

      conn
      |> auth_conn(user)
      |> post("/api/gdpr/consent", %{consent: true, type: "writing_assistant"})

      refute_enqueued(worker: WritingAssistantDataPurgeWorker)
    end

    test "an unknown consent type is rejected with 422 (whitelist)", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/gdpr/consent", %{consent: true, type: "marketing_🎯"})

      assert %{"error" => _} = json_response(conn, 422)
      refute_enqueued(worker: WritingAssistantDataPurgeWorker)
    end

    test "invalid consent value with a valid type is rejected with 422", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/gdpr/consent", %{consent: "maybe", type: "writing_assistant"})

      assert %{"error" => _} = json_response(conn, 422)
    end
  end
end
