defmodule StacksWeb.Plugs.ViewAsPlugTest do
  @moduledoc """
      Tests for StacksWeb.Plugs.ViewAsPlug — two-phase ViewAs support.

      Phase 1 (plug): parses `?view_as=` and stores `requested_perspective`.
      Phase 2 (authorize_view_as/2): checks ownership and sets `view_as_context`.
  """

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias StacksWeb.Plugs.ViewAsPlug

  defp with_current_user(conn, user) do
    Guardian.Plug.put_current_resource(conn, user)
  end

  defp call_plug(conn, params) do
    conn
    |> Map.put(:query_params, params)
    |> ViewAsPlug.call(ViewAsPlug.init([]))
  end

  describe "Phase 1 — no ?view_as param" do
    test "is a no-op when no view_as param is present", %{conn: conn} do
      result = call_plug(conn, %{})

      refute result.halted
      refute Map.has_key?(result.assigns, :requested_perspective)
    end
  end

  describe "Phase 1 — valid perspectives" do
    test "parses unauthenticated", %{conn: conn} do
      result = call_plug(conn, %{"view_as" => "unauthenticated"})

      refute result.halted
      assert result.assigns[:requested_perspective] == :unauthenticated
    end

    test "parses platform", %{conn: conn} do
      result = call_plug(conn, %{"view_as" => "platform"})

      refute result.halted
      assert result.assigns[:requested_perspective] == :platform
    end

    test "parses user:<uuid>", %{conn: conn} do
      uuid = Ecto.UUID.generate()
      result = call_plug(conn, %{"view_as" => "user:#{uuid}"})

      refute result.halted
      assert result.assigns[:requested_perspective] == {:specific_user, uuid}
    end
  end

  describe "Phase 1 — invalid perspectives halt 422" do
    test "user: (missing id) receives 422", %{conn: conn} do
      result = call_plug(conn, %{"view_as" => "user:"})

      assert result.halted
      assert result.status == 422
    end

    test "group:<id> receives 422 not_implemented", %{conn: conn} do
      result = call_plug(conn, %{"view_as" => "group:some-uuid"})

      assert result.halted
      assert result.status == 422
    end

    test "group: (missing id) receives 422", %{conn: conn} do
      result = call_plug(conn, %{"view_as" => "group:"})

      assert result.halted
      assert result.status == 422
    end

    test "unknown perspective receives 422", %{conn: conn} do
      result = call_plug(conn, %{"view_as" => "garbage_value"})

      assert result.halted
      assert result.status == 422
    end
  end

  describe "Phase 2 — no requested perspective" do
    test "is a no-op when no perspective was requested", %{conn: conn} do
      user = insert(:user)
      conn = with_current_user(conn, user)

      result = ViewAsPlug.authorize_view_as(conn, user.id)

      refute result.halted
      refute Map.has_key?(result.assigns, :view_as_context)
    end
  end

  describe "Phase 2 — platform owner" do
    test "owner can use unauthenticated on any resource", %{conn: conn} do
      owner = insert(:user, role: "owner")
      other = insert(:user)

      result =
        conn
        |> with_current_user(owner)
        |> Plug.Conn.assign(:requested_perspective, :unauthenticated)
        |> ViewAsPlug.authorize_view_as(other.id)

      refute result.halted
      assert result.assigns[:view_as_context] == :unauthenticated
    end

    test "owner can use platform", %{conn: conn} do
      owner = insert(:user, role: "owner")

      result =
        conn
        |> with_current_user(owner)
        |> Plug.Conn.assign(:requested_perspective, :platform)
        |> ViewAsPlug.authorize_view_as(Ecto.UUID.generate())

      refute result.halted
      assert result.assigns[:view_as_context] == :platform_preview
    end

    test "owner can use specific_user", %{conn: conn} do
      owner = insert(:user, role: "owner")
      target = insert(:user)

      result =
        conn
        |> with_current_user(owner)
        |> Plug.Conn.assign(:requested_perspective, {:specific_user, target.id})
        |> ViewAsPlug.authorize_view_as(Ecto.UUID.generate())

      refute result.halted
      assert result.assigns[:view_as_context] == {:platform_user, target.id}
    end
  end

  describe "Phase 2 — resource owner" do
    test "resource owner can use unauthenticated on their own resource", %{conn: conn} do
      user = insert(:user, role: "user")

      result =
        conn
        |> with_current_user(user)
        |> Plug.Conn.assign(:requested_perspective, :unauthenticated)
        |> ViewAsPlug.authorize_view_as(user.id)

      refute result.halted
      assert result.assigns[:view_as_context] == :unauthenticated
    end

    test "resource owner can use platform on their own resource", %{conn: conn} do
      user = insert(:user, role: "user")

      result =
        conn
        |> with_current_user(user)
        |> Plug.Conn.assign(:requested_perspective, :platform)
        |> ViewAsPlug.authorize_view_as(user.id)

      refute result.halted
      assert result.assigns[:view_as_context] == :platform_preview
    end

    test "resource owner cannot use specific_user — receives 403", %{conn: conn} do
      user = insert(:user, role: "user")
      target = insert(:user)

      result =
        conn
        |> with_current_user(user)
        |> Plug.Conn.assign(:requested_perspective, {:specific_user, target.id})
        |> ViewAsPlug.authorize_view_as(user.id)

      assert result.halted
      assert result.status == 403
    end
  end

  describe "Phase 2 — non-owner" do
    test "non-owner receives 403", %{conn: conn} do
      user = insert(:user, role: "user")
      other = insert(:user)

      result =
        conn
        |> with_current_user(user)
        |> Plug.Conn.assign(:requested_perspective, :unauthenticated)
        |> ViewAsPlug.authorize_view_as(other.id)

      assert result.halted
      assert result.status == 403
    end

    test "unauthenticated user receives 403", %{conn: conn} do
      result =
        conn
        |> Plug.Conn.assign(:requested_perspective, :unauthenticated)
        |> ViewAsPlug.authorize_view_as(Ecto.UUID.generate())

      assert result.halted
      assert result.status == 403
    end
  end
end
