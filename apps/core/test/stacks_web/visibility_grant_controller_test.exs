defmodule StacksWeb.VisibilityGrantControllerTest do
  @moduledoc "Tests for VisibilityGrantController endpoints."

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp group_bookshelf(user) do
    insert(:bookshelf, user: user, visibility: "group")
  end

  # ---------------------------------------------------------------------------
  # POST /api/bookshelves/:bookshelf_id/grants
  # ---------------------------------------------------------------------------

  describe "POST /api/bookshelves/:bookshelf_id/grants" do
    test "creates grant (201)", %{conn: conn} do
      owner = insert(:user)
      bookshelf = group_bookshelf(owner)
      grantee = insert(:user)

      conn =
        conn
        |> auth_conn(owner)
        |> post("/api/bookshelves/#{bookshelf.id}/grants", %{user_id: grantee.id})

      assert %{"grant" => grant} = json_response(conn, 201)
      assert grant["granted_to_id"] == grantee.id
      assert grant["resource_id"] == bookshelf.id
    end

    test "returns 403 for non-owner", %{conn: conn} do
      owner = insert(:user)
      bookshelf = group_bookshelf(owner)
      other = insert(:user)
      grantee = insert(:user)

      conn =
        conn
        |> auth_conn(other)
        |> post("/api/bookshelves/#{bookshelf.id}/grants", %{user_id: grantee.id})

      assert json_response(conn, 403)
    end

    test "returns 422 for non-group bookshelf", %{conn: conn} do
      owner = insert(:user)
      bookshelf = insert(:bookshelf, user: owner, visibility: "owner")
      grantee = insert(:user)

      conn =
        conn
        |> auth_conn(owner)
        |> post("/api/bookshelves/#{bookshelf.id}/grants", %{user_id: grantee.id})

      assert %{"error" => _} = json_response(conn, 422)
    end

    test "returns 422 for duplicate grant", %{conn: conn} do
      owner = insert(:user)
      bookshelf = group_bookshelf(owner)
      grantee = insert(:user)

      first =
        conn
        |> auth_conn(owner)
        |> post("/api/bookshelves/#{bookshelf.id}/grants", %{user_id: grantee.id})

      assert json_response(first, 201)

      second =
        build_conn()
        |> auth_conn(owner)
        |> post("/api/bookshelves/#{bookshelf.id}/grants", %{user_id: grantee.id})

      assert %{"error" => _} = json_response(second, 422)
    end

    test "returns 404 for non-existent bookshelf", %{conn: conn} do
      user = insert(:user)
      grantee = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/bookshelves/#{Ecto.UUID.generate()}/grants", %{user_id: grantee.id})

      assert json_response(conn, 404)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn = post(conn, "/api/bookshelves/#{Ecto.UUID.generate()}/grants", %{user_id: "x"})
      assert conn.status == 401
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/bookshelves/:bookshelf_id/grants
  # ---------------------------------------------------------------------------

  describe "GET /api/bookshelves/:bookshelf_id/grants" do
    test "lists grants for owner (200)", %{conn: conn} do
      owner = insert(:user)
      bookshelf = group_bookshelf(owner)
      grantee1 = insert(:user)
      grantee2 = insert(:user)

      insert(:visibility_grant,
        resource_id: bookshelf.id,
        granted_to: grantee1,
        granted_by: owner
      )

      insert(:visibility_grant,
        resource_id: bookshelf.id,
        granted_to: grantee2,
        granted_by: owner
      )

      conn =
        conn
        |> auth_conn(owner)
        |> get("/api/bookshelves/#{bookshelf.id}/grants")

      assert %{"grants" => grants} = json_response(conn, 200)
      assert length(grants) == 2
    end

    test "returns empty list when no grants", %{conn: conn} do
      owner = insert(:user)
      bookshelf = group_bookshelf(owner)

      conn =
        conn
        |> auth_conn(owner)
        |> get("/api/bookshelves/#{bookshelf.id}/grants")

      assert %{"grants" => []} = json_response(conn, 200)
    end

    test "returns 403 for non-owner", %{conn: conn} do
      owner = insert(:user)
      bookshelf = group_bookshelf(owner)
      other = insert(:user)

      conn =
        conn
        |> auth_conn(other)
        |> get("/api/bookshelves/#{bookshelf.id}/grants")

      assert json_response(conn, 403)
    end

    test "returns 404 for non-existent bookshelf", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/bookshelves/#{Ecto.UUID.generate()}/grants")

      assert json_response(conn, 404)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn = get(conn, "/api/bookshelves/#{Ecto.UUID.generate()}/grants")
      assert conn.status == 401
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE /api/bookshelves/:bookshelf_id/grants/:user_id
  # ---------------------------------------------------------------------------

  describe "DELETE /api/bookshelves/:bookshelf_id/grants/:user_id" do
    test "revokes grant (204)", %{conn: conn} do
      owner = insert(:user)
      bookshelf = group_bookshelf(owner)
      grantee = insert(:user)

      insert(:visibility_grant,
        resource_id: bookshelf.id,
        granted_to: grantee,
        granted_by: owner
      )

      conn =
        conn
        |> auth_conn(owner)
        |> delete("/api/bookshelves/#{bookshelf.id}/grants/#{grantee.id}")

      assert response(conn, 204) == ""
    end

    test "returns 403 for non-owner", %{conn: conn} do
      owner = insert(:user)
      bookshelf = group_bookshelf(owner)
      grantee = insert(:user)
      other = insert(:user)

      insert(:visibility_grant,
        resource_id: bookshelf.id,
        granted_to: grantee,
        granted_by: owner
      )

      conn =
        conn
        |> auth_conn(other)
        |> delete("/api/bookshelves/#{bookshelf.id}/grants/#{grantee.id}")

      assert json_response(conn, 403)
    end

    test "returns 404 for non-existent grant", %{conn: conn} do
      owner = insert(:user)
      bookshelf = group_bookshelf(owner)
      user = insert(:user)

      conn =
        conn
        |> auth_conn(owner)
        |> delete("/api/bookshelves/#{bookshelf.id}/grants/#{user.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        delete(
          conn,
          "/api/bookshelves/#{Ecto.UUID.generate()}/grants/#{Ecto.UUID.generate()}"
        )

      assert conn.status == 401
    end
  end
end
