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

  alias Core.Repo
  alias Stacks.Accounts.AuthTokenFamily
  alias Stacks.Accounts.Guardian
  alias Stacks.Workers.{AccountDeletionJob, DataExportJob, WritingAssistantDataPurgeWorker}
  alias StacksWeb.Plugs.SessionCookie

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

    # ⛔ THE SESSION MUST END ON THE 202, not when the Oban job happens to run.
    # Before this, `delete_account/2` queued the erasure and returned 202 while the
    # caller's browser kept a working credential for the account it had just asked
    # to erase — for as long as the queue took.
    #
    # ⚖️ These three assert the three halves separately, because each can be got
    # right while another is missed: the cookie the browser carries, the token it
    # presents, and the FAMILY that token belongs to. Revoking only the presented
    # token leaves every refresh sibling live.
    test "the 202 clears the session cookie", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> delete("/api/gdpr/account")

      assert %{"status" => "accepted"} = json_response(conn, 202)

      cookie_name = SessionCookie.cookie_name()
      assert %{^cookie_name => cleared} = conn.resp_cookies

      # ⚠️ MEASURED, NOT ASSUMED. This was first written as `cleared.value == ""`
      # and failed: a Plug deletion carries NO `:value` key at all, only
      # `max_age: 0` and a `universal_time` at the epoch. Asserting the shape Plug
      # actually produces, rather than the serialised `Set-Cookie` text, which
      # would couple this to Plug's formatting.
      refute Map.has_key?(cleared, :value)
      assert cleared.max_age == 0
      assert cleared.universal_time == {{1970, 1, 1}, {0, 0, 0}}

      # ⛔ And the attributes must survive the clearing: a Set-Cookie that drops
      # `secure` or `http_only` is a different cookie to the browser, which may
      # then keep the one it has.
      assert cleared.http_only
      assert cleared.secure
    end

    test "the presented token no longer authenticates", %{conn: conn} do
      user = insert(:user, email_confirmed: true)
      {:ok, token, _claims} = Guardian.encode_and_sign(user)

      # ⛔ ANTI-VACUITY, and it is the half that makes the rest mean something: the
      # token must WORK first. Without this the test below passes against a token
      # that was never valid, which is indistinguishable from one that was revoked.
      pre =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/auth/me")

      assert json_response(pre, 200)

      deletion =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> delete("/api/gdpr/account")

      assert json_response(deletion, 202)

      post =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/auth/me")

      assert json_response(post, 401)
    end

    test "the token family is revoked, so a refresh sibling is refused too", %{conn: conn} do
      insert(:user,
        email: "deleting-family@example.com",
        password_hash: Argon2.hash_pwd_salt("secret123"),
        email_confirmed: true
      )

      # ⚠️ Through a real LOGIN, because that is what mints the family row. A
      # `Guardian.encode_and_sign/1` token carries no `family_id`, so a test built
      # on one would assert the family branch while never entering it.
      login =
        post(conn, "/api/auth/login", %{
          email: "deleting-family@example.com",
          password: "secret123"
        })

      assert %{"token" => token} = json_response(login, 200)
      assert {:ok, claims} = Guardian.decode_and_verify(token)
      family_id = claims["family_id"]
      assert is_binary(family_id)

      family_before = Repo.get(AuthTokenFamily, family_id)
      assert is_nil(family_before.revoked_at)

      deletion =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> delete("/api/gdpr/account")

      assert json_response(deletion, 202)

      family_after = Repo.get(AuthTokenFamily, family_id)
      refute is_nil(family_after.revoked_at)
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
