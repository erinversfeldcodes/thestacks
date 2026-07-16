defmodule StacksWeb.BookModerationControllerTest do
  @moduledoc """
  Tests for the owner age-gate moderation admin API endpoints (#118).

  The owner sees ALL books (including age-gated ones hidden from the public
  catalogue) and may override a book's visibility tier in EITHER direction.
  Access is gated by the MFA-verified admin session pipeline.
  """

  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Admin.SessionContext

  defp setup_admin_conn(conn) do
    user = insert(:owner_user)
    boot_id = Core.Application.boot_id()
    raw_ip = "127.0.0.1"
    {:ok, session} = SessionContext.create(user, raw_ip, boot_id)
    {:ok, session} = SessionContext.mark_mfa_verified(session)

    {:ok, token, _} =
      Guardian.encode_and_sign(user, %{},
        token_type: "admin",
        session_id: session.id,
        boot_id: boot_id,
        ttl: {30, :minute}
      )

    conn = put_req_header(conn, "authorization", "Bearer #{token}")
    {conn, user, session}
  end

  defp owner_conn(conn) do
    user = insert(:owner_user)
    {:ok, token, _} = Guardian.encode_and_sign(user)
    conn = put_req_header(conn, "authorization", "Bearer #{token}")
    {conn, user}
  end

  describe "GET /api/admin/books" do
    test "returns paginated list of books including age-gated ones", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)
      insert(:book, title: "Public Book", visibility_tier: "public")
      insert(:book, title: "Adult Book", visibility_tier: "age_gated")

      conn = get(conn, "/api/admin/books")

      assert %{"books" => books, "total" => 2, "page" => 1, "per_page" => 50} =
               json_response(conn, 200)

      assert length(books) == 2
      tiers = Enum.map(books, & &1["visibility_tier"])
      assert "age_gated" in tiers
      assert "public" in tiers
    end

    test "filters by tier=age_gated", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)
      insert(:book, visibility_tier: "public")
      insert(:book, visibility_tier: "age_gated")

      conn = get(conn, "/api/admin/books", %{"tier" => "age_gated"})

      assert %{"books" => books, "total" => 1} = json_response(conn, 200)
      assert hd(books)["visibility_tier"] == "age_gated"
    end

    test "filters by search on title", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)
      insert(:book, title: "Dune")
      insert(:book, title: "Neuromancer")

      conn = get(conn, "/api/admin/books", %{"search" => "Dune"})

      assert %{"books" => books, "total" => 1} = json_response(conn, 200)
      assert hd(books)["title"] == "Dune"
    end

    test "returns 401 for regular owner JWT (no MFA)", %{conn: conn} do
      {conn, _user} = owner_conn(conn)

      conn = get(conn, "/api/admin/books")

      assert conn.status == 401
    end

    test "returns 401 for unauthenticated request", %{conn: conn} do
      conn = get(conn, "/api/admin/books")
      assert conn.status == 401
    end
  end

  describe "PUT /api/admin/books/:id/age-gate" do
    test "owner raises the gate: public -> age_gated", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)
      book = insert(:book, visibility_tier: "public")

      conn = put(conn, "/api/admin/books/#{book.id}/age-gate", %{"age_gated" => true})

      assert %{"book" => result} = json_response(conn, 200)
      assert result["id"] == book.id
      assert result["visibility_tier"] == "age_gated"
    end

    test "owner lowers the gate: age_gated -> public (owner-only direction)", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)
      book = insert(:book, visibility_tier: "age_gated")

      conn = put(conn, "/api/admin/books/#{book.id}/age-gate", %{"age_gated" => false})

      assert %{"book" => result} = json_response(conn, 200)
      assert result["id"] == book.id
      assert result["visibility_tier"] == "public"
    end

    test "accepts explicit visibility_tier param", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)
      book = insert(:book, visibility_tier: "public")

      conn =
        put(conn, "/api/admin/books/#{book.id}/age-gate", %{"visibility_tier" => "age_gated"})

      assert %{"book" => result} = json_response(conn, 200)
      assert result["visibility_tier"] == "age_gated"
    end

    test "returns 404 for nonexistent book", %{conn: conn} do
      {conn, _user, _session} = setup_admin_conn(conn)

      conn =
        put(conn, "/api/admin/books/#{Ecto.UUID.generate()}/age-gate", %{"age_gated" => true})

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "returns 401 for regular owner JWT (no MFA)", %{conn: conn} do
      {conn, _user} = owner_conn(conn)
      book = insert(:book, visibility_tier: "public")

      conn = put(conn, "/api/admin/books/#{book.id}/age-gate", %{"age_gated" => true})

      assert conn.status == 401
    end
  end
end
