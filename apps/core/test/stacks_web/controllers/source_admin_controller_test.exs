defmodule StacksWeb.SourceAdminControllerTest do
  @moduledoc """
  Tests for the source approval admin API endpoints.
  """

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "GET /api/admin/sources" do
    test "returns paginated list of sources for owner", %{conn: conn} do
      owner = insert(:owner_user)
      insert(:discovered_source, status: "pending_review")
      insert(:discovered_source, status: "approved")

      conn =
        conn
        |> auth_conn(owner)
        |> get("/api/admin/sources")

      assert %{"sources" => sources, "total" => 2, "page" => 1} = json_response(conn, 200)
      assert length(sources) == 2
    end

    test "filters by status", %{conn: conn} do
      owner = insert(:owner_user)
      insert(:discovered_source, status: "pending_review")
      insert(:discovered_source, status: "approved", approved_at: DateTime.utc_now())

      conn =
        conn
        |> auth_conn(owner)
        |> get("/api/admin/sources", %{"status" => "pending_review"})

      assert %{"sources" => sources, "total" => 1} = json_response(conn, 200)
      assert length(sources) == 1
      assert hd(sources)["status"] == "pending_review"
    end

    test "filters by type", %{conn: conn} do
      owner = insert(:owner_user)
      insert(:discovered_source, type: "bookshop")
      insert(:discovered_source, type: "review_site")

      conn =
        conn
        |> auth_conn(owner)
        |> get("/api/admin/sources", %{"type" => "bookshop"})

      assert %{"sources" => sources, "total" => 1} = json_response(conn, 200)
      assert hd(sources)["type"] == "bookshop"
    end

    test "returns 403 for non-owner", %{conn: conn} do
      user = insert(:user, role: "user")

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/admin/sources")

      assert json_response(conn, 403)
    end

    test "returns 401 for unauthenticated request", %{conn: conn} do
      conn = get(conn, "/api/admin/sources")
      assert conn.status == 401
    end
  end

  describe "PUT /api/admin/sources/:id/approve" do
    test "transitions pending_review to approved", %{conn: conn} do
      owner = insert(:owner_user)
      source = insert(:discovered_source, status: "pending_review")

      conn =
        conn
        |> auth_conn(owner)
        |> put("/api/admin/sources/#{source.id}/approve")

      assert %{"source" => result} = json_response(conn, 200)
      assert result["id"] == source.id
      assert result["status"] == "approved"
      assert result["approved_at"] != nil
    end

    test "returns 422 for already approved source", %{conn: conn} do
      owner = insert(:owner_user)
      source = insert(:discovered_source, status: "approved", approved_at: DateTime.utc_now())

      conn =
        conn
        |> auth_conn(owner)
        |> put("/api/admin/sources/#{source.id}/approve")

      assert %{"error" => "invalid state transition"} = json_response(conn, 422)
    end

    test "returns 404 for nonexistent source", %{conn: conn} do
      owner = insert(:owner_user)

      conn =
        conn
        |> auth_conn(owner)
        |> put("/api/admin/sources/#{Ecto.UUID.generate()}/approve")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "returns 403 for non-owner", %{conn: conn} do
      user = insert(:user, role: "user")
      source = insert(:discovered_source, status: "pending_review")

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/admin/sources/#{source.id}/approve")

      assert json_response(conn, 403)
    end
  end

  describe "PUT /api/admin/sources/:id/reject" do
    test "transitions pending_review to dismissed", %{conn: conn} do
      owner = insert(:owner_user)
      source = insert(:discovered_source, status: "pending_review")

      conn =
        conn
        |> auth_conn(owner)
        |> put("/api/admin/sources/#{source.id}/reject")

      assert %{"source" => result} = json_response(conn, 200)
      assert result["id"] == source.id
      assert result["status"] == "dismissed"
    end

    test "returns 422 for already dismissed source", %{conn: conn} do
      owner = insert(:owner_user)
      source = insert(:discovered_source, status: "dismissed")

      conn =
        conn
        |> auth_conn(owner)
        |> put("/api/admin/sources/#{source.id}/reject")

      assert %{"error" => "invalid state transition"} = json_response(conn, 422)
    end

    test "returns 404 for nonexistent source", %{conn: conn} do
      owner = insert(:owner_user)

      conn =
        conn
        |> auth_conn(owner)
        |> put("/api/admin/sources/#{Ecto.UUID.generate()}/reject")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end
end
