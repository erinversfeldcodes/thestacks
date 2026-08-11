defmodule StacksWeb.InviteAdminControllerTest do
  @moduledoc """
    — the owner's invitation endpoints, driven through the REAL admin
    pipeline. That last part is the lesson this file records: the unit tests
    called `Invites.issue/2` with a user in hand, so the controller reading the
    wrong conn key (`Guardian.Plug.current_resource/1`, nil under
    `AdminAuthPipeline`, which assigns `:current_user`) shipped green and 500'd
    on the first live mint (2026-08-10).
  """
  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Admin.SessionContext

  defp admin_session(conn, user) do
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

  defp as_owner(conn), do: admin_session(conn, insert(:owner_user))

  test "the owner can mint, list (prefix only), and revoke through the pipeline", %{conn: conn} do
    conn = as_owner(conn)

    created = post(conn, "/api/admin/invites", %{"note" => "Mara — book club"})
    assert %{"invite" => %{"code" => code, "id" => id}} = json_response(created, 201)
    assert String.starts_with?(code, "STK-")

    listed = get(conn, "/api/admin/invites")
    assert %{"invites" => [row | _]} = json_response(listed, 200)
    refute Map.has_key?(row, "code")
    assert String.starts_with?(code, row["code_prefix"])

    revoked = delete(conn, "/api/admin/invites/#{id}")
    assert %{"invite" => %{"revoked_at" => revoked_at}} = json_response(revoked, 200)
    assert revoked_at
  end

  test "a non-owner admin session is refused — the beta cannot be widened sideways", %{conn: conn} do
    conn = admin_session(conn, insert(:user))

    assert conn |> post("/api/admin/invites", %{}) |> json_response(403)
  end
end
