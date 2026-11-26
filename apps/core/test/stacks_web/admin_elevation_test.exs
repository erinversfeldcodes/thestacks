defmodule StacksWeb.AdminElevationTest do
  @moduledoc """
      The admin chain as the ROUTER assembles it, driven through a real admin
      route.

      ⛔ WHY THIS EXISTS SEPARATELY FROM `RequireMFATest`. That file calls
      `RequireMFA` directly with a hand-assigned `admin_session`, so it proves
      the plug refuses an unverified session — and it stays green if the plug
      stops being piped at all. The change that moved elevation off a
      client-held token and onto the session rewrote `AdminAuthPipeline` and
      `pipeline :admin` together, and the cheapest way to make "a reload does
      not re-prompt" true is to drop the requirement rather than to replay it.
      Nothing asserted `mfa_required` anywhere in the suite, so nothing would
      have noticed.

      These cases go through `pipe_through [:api, :admin, …]` end to end:
      `AuthPipeline` → `AdminAuthPipeline` → `RequireMFA` → `AuditAdminCall`.
  """

  use CoreWeb.ConnCase, async: false

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts.Guardian
  alias Stacks.Admin.SessionContext
  alias Stacks.AdminSession

  @admin_route "/api/admin/sources"

  # An operator with an ordinary session and an admin session that has NEVER
  # been MFA-verified. Deliberately not `elevated_conn/2` — that helper calls
  # `mark_mfa_verified/1`, which is the thing under test here.
  defp unelevated_conn(conn) do
    user = insert(:owner_user)
    {:ok, session} = SessionContext.create(user, "127.0.0.1", Core.Application.boot_id())
    {:ok, token, _} = Guardian.encode_and_sign(user)

    {with_session(conn, token), user, session}
  end

  defp backdate_elevation(session, minutes) do
    at = DateTime.add(DateTime.utc_now(), -minutes, :minute)

    {1, _} =
      Repo.update_all(
        from(s in AdminSession, where: s.id == ^session.id),
        set: [mfa_verified_at: at]
      )

    :ok
  end

  describe "the admin chain, through the router" do
    test "an elevated operator reaches an admin route", %{conn: conn} do
      {conn, _user, _session} = elevated_conn(conn)

      assert json_response(get(conn, @admin_route), 200)
    end

    test "an operator who has never verified MFA is refused", %{conn: conn} do
      {conn, _user, _session} = unelevated_conn(conn)

      assert %{"error" => "mfa_required"} = json_response(get(conn, @admin_route), 403)
    end

    test "an operator whose elevation has aged out of the window is refused", %{conn: conn} do
      {conn, _user, session} = elevated_conn(conn)
      :ok = backdate_elevation(session, 31)

      assert %{"error" => "mfa_required"} = json_response(get(conn, @admin_route), 403)
    end

    test "elevation just inside the window is still accepted", %{conn: conn} do
      # ⚠️ The anti-vacuity half of the case above. Without it, a chain that
      # refused EVERY elevation would pass the refusal tests and fail nobody.
      {conn, _user, session} = elevated_conn(conn)
      :ok = backdate_elevation(session, 29)

      assert json_response(get(conn, @admin_route), 200)
    end

    test "a second request on the same cookie is still elevated — the proof is replayed, not spent",
         %{conn: conn} do
      # ⛔ THIS IS THE REQUEST-LEVEL FORM OF "A RELOAD DOES NOT RE-PROMPT".
      # Before the change, elevation lived in a second Guardian token the SPA
      # held in memory; a reload dropped it and the operator was asked to prove
      # something the server had already recorded. Now the cookie is all the
      # client carries, so the same cookie must keep working — and nothing
      # about serving one request may consume the elevation.
      {conn, _user, _session} = elevated_conn(conn)

      assert json_response(get(conn, @admin_route), 200)

      # A fresh conn carrying the same session, as a reload would send.
      assert json_response(get(recycle(conn), @admin_route), 200)
    end
  end
end
