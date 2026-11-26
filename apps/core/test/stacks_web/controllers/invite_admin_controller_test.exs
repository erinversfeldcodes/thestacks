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
    {:ok, _session} = SessionContext.mark_mfa_verified(session)

    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  # A valid admin session that has NOT cleared the second factor — the state a
  # session is in between login and MFA verification.
  defp admin_session_unverified(conn, user) do
    {:ok, _session} = SessionContext.create(user, "127.0.0.1", Core.Application.boot_id())

    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp as_owner(conn), do: admin_session(conn, insert(:owner_user))

  # Run the request under the real application role, not the test superuser, so a
  # refusal is proven to come from the role check — not a table privilege the
  # superuser holds and the app role does not. SET LOCAL is scoped to the sandbox
  # transaction, so it reverts at the end of the test on its own.
  defp with_app_role!, do: Core.Repo.query!("SET LOCAL ROLE stacks_app")

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

  describe "the owner gate runs before the second factor" do
    test "a non-owner is refused as a 404 — never a 403, never the MFA prompt", %{conn: conn} do
      conn = admin_session_unverified(conn, insert(:user))
      with_app_role!()

      conn = post(conn, "/api/admin/invites", %{})

      # 404, not 403 (the surface does not admit it is real) and not the
      # `mfa_required` prompt (the owner check settled this before the second
      # factor could be offered). The body is the API's own not-found shape.
      assert conn.status == 404
      assert json_response(conn, 404) == %{"error" => "not_found"}
    end

    test "the refusal is byte-identical to a route that does not exist", %{conn: conn} do
      # One non-owner session, used for both probes — the real threat model is an
      # attacker who already holds a (non-owner) session and compares a real-but-
      # gated admin path against a made-up one.
      conn = admin_session_unverified(conn, insert(:user))
      with_app_role!()

      gated = post(conn, "/api/admin/invites", %{})
      absent = post(conn, "/api/admin/this-admin-route-does-not-exist", %{})

      # The gated surface must be indistinguishable from the absent one: same
      # status, same body.
      assert gated.status == 404
      assert absent.status == 404
      assert json_response(gated, 404) == json_response(absent, 404)
    end

    test "an un-verified OWNER passes the gate and is then stopped by the second factor",
         %{conn: conn} do
      conn = admin_session_unverified(conn, insert(:owner_user))

      conn = post(conn, "/api/admin/invites", %{"note" => "x"})

      # The owner is NOT hidden from their own surface — they clear the role gate
      # and meet the MFA prompt, the opposite of the non-owner's 404.
      assert %{"error" => "mfa_required"} = json_response(conn, 403)
    end
  end
end
