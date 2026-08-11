defmodule StacksWeb.AuditLogControllerTest do
  @moduledoc """
      Tests for the read-only GDPR audit-log endpoint
      (`GET /api/settings/audit-log`).

      The endpoint returns ONLY the authenticated user's own audit rows,
      paginated, with `metadata` decrypted for display and hashed IPs never
      exposed.
  """

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Audit

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "GET /api/settings/audit-log" do
    test "returns 401 when unauthenticated", %{conn: conn} do
      conn = get(conn, "/api/settings/audit-log")
      assert json_response(conn, 401)
    end

    test "returns the authenticated user's audit entries", %{conn: conn} do
      user = insert(:user)

      {:ok, _} =
        Audit.log(user.id, "user.login",
          resource_type: "user",
          resource_id: user.id,
          metadata: %{"detail" => "signed in"}
        )

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/settings/audit-log")

      body = json_response(conn, 200)
      assert %{"entries" => [entry], "total" => 1, "page" => 1, "per_page" => _} = body
      assert entry["action"] == "user.login"
      assert entry["resource_type"] == "user"
      assert entry["occurred_at"]
    end

    test "decrypts metadata via Stacks.Vault for display", %{conn: conn} do
      user = insert(:user)

      {:ok, _} =
        Audit.log(user.id, "user.export_requested",
          resource_type: "user",
          metadata: %{"scope" => "full", "secret" => "plaintext-after-decrypt"}
        )

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/settings/audit-log")

      %{"entries" => [entry]} = json_response(conn, 200)

      assert entry["metadata"] == %{
               "scope" => "full",
               "secret" => "plaintext-after-decrypt"
             }
    end

    test "never exposes a raw or hashed IP in the response", %{conn: conn} do
      user = insert(:user)

      {:ok, _} =
        Audit.log(user.id, "user.login",
          resource_type: "user",
          ip: "203.0.113.7",
          metadata: %{"detail" => "signed in"}
        )

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/settings/audit-log")

      body = json_response(conn, 200)
      %{"entries" => [entry]} = body

      refute Map.has_key?(entry, "ip")
      refute Map.has_key?(entry, "ip_address")
      refute Map.has_key?(entry, "ip_hash")

      ip_hash = :crypto.hash(:sha256, "203.0.113.7") |> Base.encode16(case: :lower)
      serialised = Jason.encode!(body)
      refute serialised =~ ip_hash
      refute serialised =~ "203.0.113.7"
    end

    test "excludes other users' audit rows (cross-user isolation)", %{conn: conn} do
      user = insert(:user)
      other = insert(:user)

      {:ok, _} =
        Audit.log(user.id, "user.login", resource_type: "user", metadata: %{"who" => "mine"})

      {:ok, _} =
        Audit.log(other.id, "user.login",
          resource_type: "user",
          metadata: %{"who" => "theirs"}
        )

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/settings/audit-log")

      %{"entries" => entries, "total" => total} = json_response(conn, 200)

      assert total == 1
      assert length(entries) == 1
      assert [%{"metadata" => %{"who" => "mine"}}] = entries
    end

    test "paginates results with page/per_page and orders newest first", %{conn: conn} do
      user = insert(:user)

      for n <- 1..3 do
        {:ok, _} =
          Audit.log(user.id, "action.#{n}",
            resource_type: "user",
            metadata: %{"n" => n}
          )
      end

      conn1 =
        conn
        |> auth_conn(user)
        |> get("/api/settings/audit-log", %{"page" => "1", "per_page" => "2"})

      body1 = json_response(conn1, 200)
      assert body1["total"] == 3
      assert body1["page"] == 1
      assert body1["per_page"] == 2
      assert length(body1["entries"]) == 2

      assert [%{"action" => "action.3"}, %{"action" => "action.2"}] = body1["entries"]

      conn2 =
        build_conn()
        |> auth_conn(user)
        |> get("/api/settings/audit-log", %{"page" => "2", "per_page" => "2"})

      body2 = json_response(conn2, 200)
      assert body2["page"] == 2
      assert length(body2["entries"]) == 1
      assert [%{"action" => "action.1"}] = body2["entries"]
    end
  end
end
