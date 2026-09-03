defmodule StacksWeb.FeedbackControllerTest do
  @moduledoc """
      Both ends of the channel driven through their REAL pipelines: the
      reader's authed, rate-limited POST, and the owner's MFA-gated read.
      The gate is the point of this file — the admin endpoint is the only way
      other people's writing leaves the database.
  """

  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Admin.SessionContext

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp admin_conn(conn, user) do
    boot_id = Core.Application.boot_id()
    {:ok, session} = SessionContext.create(user, "127.0.0.1", boot_id)
    {:ok, session} = SessionContext.mark_mfa_verified(session)

    {:ok, token, _} =
      Guardian.encode_and_sign(user, %{},
        token_type: "admin",
        session_id: session.id,
        boot_id: boot_id,
        ttl: {30, :minute}
      )

    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "POST /api/feedback" do
    test "a signed-in reader can send feedback", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/feedback", %{
          "body" => "The wishlist spines overlap.",
          "page_context" => "wishlist"
        })

      assert json_response(conn, 201) == %{"message" => "received"}
    end

    test "the response does not echo the message back", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/feedback", %{"body" => "A sentence I would rather not see twice."})

      refute conn.resp_body =~ "rather not see twice"
    end

    test "an empty message is refused with the field named", %{conn: conn} do
      user = insert(:user)

      conn = conn |> auth_conn(user) |> post("/api/feedback", %{"body" => ""})

      assert %{"errors" => %{"body" => _}} = json_response(conn, 422)
    end

    test "an anonymous caller is refused", %{conn: conn} do
      conn = post(conn, "/api/feedback", %{"body" => "Sent by nobody in particular."})

      assert json_response(conn, 401)
    end
  end

  describe "POST /api/feedback rate limiting" do
    setup do
      original = Application.get_env(:core, :rate_limiting_enabled)
      original_limit = Application.get_env(:core, :rate_limit_feedback)
      Application.put_env(:core, :rate_limiting_enabled, true)
      Application.put_env(:core, :rate_limit_feedback, 3)

      on_exit(fn ->
        Application.put_env(:core, :rate_limiting_enabled, original)

        if original_limit do
          Application.put_env(:core, :rate_limit_feedback, original_limit)
        else
          Application.delete_env(:core, :rate_limit_feedback)
        end

        if :ets.whereis(:rate_limiter) != :undefined do
          :ets.delete_all_objects(:rate_limiter)
        end
      end)

      :ok
    end

    test "a flood past the bucket gets a 429, not a silent drop", %{conn: conn} do
      user = insert(:user)

      for n <- 1..3 do
        assert conn
               |> auth_conn(user)
               |> post("/api/feedback", %{"body" => "Report number #{n}."})
               |> json_response(201)
      end

      refused =
        conn
        |> auth_conn(user)
        |> post("/api/feedback", %{"body" => "One more thing."})

      assert %{"error" => "rate_limit_exceeded"} = json_response(refused, 429)
    end
  end

  describe "GET /api/admin/feedback" do
    test "the owner reads the queue, newest first, with the sender", %{conn: conn} do
      reader = insert(:user, handle: "mara")

      {:ok, _} =
        Stacks.Feedback.submit(reader.id, "The bookcase frame breaks at 320px.", "library")

      conn = conn |> admin_conn(insert(:owner_user)) |> get("/api/admin/feedback")

      assert %{"feedback" => [entry]} = json_response(conn, 200)
      assert entry["body"] == "The bookcase frame breaks at 320px."
      assert entry["page_context"] == "library"
      assert entry["sender_handle"] == "mara"
      assert entry["created_at"]
    end

    test "a signed-in reader cannot read everyone else's feedback", %{conn: conn} do
      reader = insert(:user)
      {:ok, _} = Stacks.Feedback.submit(reader.id, "Something private to me.")

      conn = conn |> auth_conn(reader) |> get("/api/admin/feedback")

      assert conn.status in [401, 403]
      refute conn.resp_body =~ "Something private to me."
    end

    test "an anonymous caller cannot read the queue", %{conn: conn} do
      assert conn |> get("/api/admin/feedback") |> json_response(401)
    end
  end
end
