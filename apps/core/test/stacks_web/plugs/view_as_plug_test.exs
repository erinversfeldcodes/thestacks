defmodule StacksWeb.Plugs.ViewAsPlugTest do
  @moduledoc """
  Tests for StacksWeb.Plugs.ViewAsPlug.

  The plug reads the `?view_as=<perspective>` query param and sets
  `conn.assigns[:view_as_context]` so downstream controllers can render
  the caller's content from the named viewer's perspective.

  Platform owners may use any perspective. Regular users may use
  "unauthenticated" and "platform" on resources they own (controller must
  set `conn.assigns[:resource_owner_id]`). Non-owners receive 403.
  Invalid perspective values receive 422.
  """

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias StacksWeb.Plugs.ViewAsPlug

  # Puts the current user into Guardian private storage so that
  # Guardian.Plug.current_resource/1 returns it from within the plug.
  defp with_current_user(conn, user) do
    Guardian.Plug.put_current_resource(conn, user)
  end

  # Simulates the plug receiving a request with a given query string.
  defp call_plug(conn, params \\ %{}) do
    conn
    |> Map.put(:query_params, params)
    |> ViewAsPlug.call(ViewAsPlug.init([]))
  end

  # ---------------------------------------------------------------------------
  # No ?view_as param
  # ---------------------------------------------------------------------------

  describe "ViewAsPlug — no ?view_as param" do
    test "is a no-op when no view_as param is present", %{conn: conn} do
      user = insert(:user)
      conn = with_current_user(conn, user)

      result = call_plug(conn, %{})

      refute result.halted
      refute Map.has_key?(result.assigns, :view_as_context)
    end

    test "is a no-op for unauthenticated requests with no view_as param", %{conn: conn} do
      result = call_plug(conn, %{})

      refute result.halted
      refute Map.has_key?(result.assigns, :view_as_context)
    end
  end

  # ---------------------------------------------------------------------------
  # Owner using ViewAs
  # ---------------------------------------------------------------------------

  describe "ViewAsPlug — owner using ViewAs" do
    test "owner with view_as=unauthenticated sets :unauthenticated context", %{conn: conn} do
      owner = insert(:user, role: "owner")
      conn = with_current_user(conn, owner)

      result = call_plug(conn, %{"view_as" => "unauthenticated"})

      refute result.halted
      assert result.assigns[:view_as_context] == :unauthenticated
    end

    test "owner with view_as=platform sets {:platform_user, owner_id} context", %{conn: conn} do
      owner = insert(:user, role: "owner")
      conn = with_current_user(conn, owner)

      result = call_plug(conn, %{"view_as" => "platform"})

      refute result.halted
      assert result.assigns[:view_as_context] == {:platform_user, owner.id}
    end

    test "owner with view_as=user:<target_id> sets {:specific_user, target_id} context", %{
      conn: conn
    } do
      owner = insert(:user, role: "owner")
      target = insert(:user)
      conn = with_current_user(conn, owner)

      result = call_plug(conn, %{"view_as" => "user:#{target.id}"})

      refute result.halted
      assert result.assigns[:view_as_context] == {:specific_user, target.id}
    end
  end

  # ---------------------------------------------------------------------------
  # Non-owner without resource_owner_id — always 403
  # ---------------------------------------------------------------------------

  describe "ViewAsPlug — non-owner without resource_owner_id" do
    test "authenticated non-owner using view_as=unauthenticated receives 403", %{conn: conn} do
      regular_user = insert(:user, role: "user")
      conn = with_current_user(conn, regular_user)

      result = call_plug(conn, %{"view_as" => "unauthenticated"})

      assert result.halted
      assert result.status == 403
    end

    test "authenticated non-owner using view_as=platform receives 403", %{conn: conn} do
      regular_user = insert(:user, role: "user")
      conn = with_current_user(conn, regular_user)

      result = call_plug(conn, %{"view_as" => "platform"})

      assert result.halted
      assert result.status == 403
    end

    test "authenticated non-owner using view_as=user:<id> receives 403", %{conn: conn} do
      regular_user = insert(:user, role: "user")
      target = insert(:user)
      conn = with_current_user(conn, regular_user)

      result = call_plug(conn, %{"view_as" => "user:#{target.id}"})

      assert result.halted
      assert result.status == 403
    end

    test "unauthenticated request with view_as param receives 403", %{conn: conn} do
      result = call_plug(conn, %{"view_as" => "unauthenticated"})

      assert result.halted
      assert result.status == 403
    end
  end

  # ---------------------------------------------------------------------------
  # Regular user with matching resource_owner_id
  # ---------------------------------------------------------------------------

  describe "ViewAsPlug — resource owner using ViewAs" do
    test "resource owner with view_as=unauthenticated sets :unauthenticated context", %{
      conn: conn
    } do
      user = insert(:user, role: "user")

      conn =
        conn
        |> with_current_user(user)
        |> Plug.Conn.assign(:resource_owner_id, user.id)

      result = call_plug(conn, %{"view_as" => "unauthenticated"})

      refute result.halted
      assert result.assigns[:view_as_context] == :unauthenticated
    end

    test "resource owner with view_as=platform sets {:platform_user, user_id} context", %{
      conn: conn
    } do
      user = insert(:user, role: "user")

      conn =
        conn
        |> with_current_user(user)
        |> Plug.Conn.assign(:resource_owner_id, user.id)

      result = call_plug(conn, %{"view_as" => "platform"})

      refute result.halted
      assert result.assigns[:view_as_context] == {:platform_user, user.id}
    end

    test "resource owner using view_as=user:<id> receives 403 (owner-only perspective)", %{
      conn: conn
    } do
      user = insert(:user, role: "user")
      target = insert(:user)

      conn =
        conn
        |> with_current_user(user)
        |> Plug.Conn.assign(:resource_owner_id, user.id)

      result = call_plug(conn, %{"view_as" => "user:#{target.id}"})

      assert result.halted
      assert result.status == 403
    end

    test "non-matching resource_owner_id receives 403", %{conn: conn} do
      user = insert(:user, role: "user")
      other_user = insert(:user)

      conn =
        conn
        |> with_current_user(user)
        |> Plug.Conn.assign(:resource_owner_id, other_user.id)

      result = call_plug(conn, %{"view_as" => "unauthenticated"})

      assert result.halted
      assert result.status == 403
    end
  end

  # ---------------------------------------------------------------------------
  # Invalid perspective
  # ---------------------------------------------------------------------------

  describe "ViewAsPlug — invalid perspective" do
    test "view_as=garbage_value receives 422 (unprocessable perspective)", %{conn: conn} do
      owner = insert(:user, role: "owner")
      conn = with_current_user(conn, owner)

      result = call_plug(conn, %{"view_as" => "garbage_value"})

      # A malformed perspective value is unprocessable — 422 is returned.
      # The plug does NOT silently pass through on unknown perspectives because
      # that would risk unintended visibility exposure.
      assert result.halted
      assert result.status == 422
    end

    test "view_as=user: (missing user id) receives 422", %{conn: conn} do
      owner = insert(:user, role: "owner")
      conn = with_current_user(conn, owner)

      result = call_plug(conn, %{"view_as" => "user:"})

      assert result.halted
      assert result.status == 422
    end

    test "view_as=group:<id> receives 422 not_implemented", %{conn: conn} do
      owner = insert(:user, role: "owner")
      conn = with_current_user(conn, owner)

      result = call_plug(conn, %{"view_as" => "group:some-uuid"})

      assert result.halted
      assert result.status == 422
    end

    test "view_as=group: (missing group id) receives 422", %{conn: conn} do
      owner = insert(:user, role: "owner")
      conn = with_current_user(conn, owner)

      result = call_plug(conn, %{"view_as" => "group:"})

      assert result.halted
      assert result.status == 422
    end
  end
end
