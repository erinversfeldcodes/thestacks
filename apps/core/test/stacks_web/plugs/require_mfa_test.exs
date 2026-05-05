defmodule StacksWeb.Plugs.RequireMFATest do
  use CoreWeb.ConnCase, async: false

  import Plug.Conn
  import Stacks.Factory

  alias Stacks.Admin.SessionContext
  alias StacksWeb.Plugs.RequireMFA

  @raw_ip "127.0.0.1"

  describe "RequireMFA" do
    test "passes when mfa_verified_at is recent", %{conn: conn} do
      user = insert(:owner_user)
      {:ok, session} = SessionContext.create(user, @raw_ip, Core.Application.boot_id())
      {:ok, session} = SessionContext.mark_mfa_verified(session)

      conn =
        conn
        |> assign(:admin_session, session)
        |> RequireMFA.call([])

      refute conn.halted
    end

    test "halts with 403 when mfa_verified_at is nil", %{conn: conn} do
      user = insert(:owner_user)
      {:ok, session} = SessionContext.create(user, @raw_ip, Core.Application.boot_id())

      conn =
        conn
        |> assign(:admin_session, session)
        |> RequireMFA.call([])

      assert conn.halted
      assert conn.status == 403
    end

    test "halts with 403 when mfa_verified_at is older than 30 minutes", %{conn: conn} do
      user = insert(:owner_user)
      {:ok, session} = SessionContext.create(user, @raw_ip, Core.Application.boot_id())

      old_time = DateTime.add(DateTime.utc_now(), -31, :minute)

      session =
        session
        |> Ecto.Changeset.change(mfa_verified_at: old_time)
        |> Core.Repo.update!()

      conn =
        conn
        |> assign(:admin_session, session)
        |> RequireMFA.call([])

      assert conn.halted
      assert conn.status == 403
    end
  end
end
