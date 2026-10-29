defmodule CoreWeb.ConnCase do
  alias Stacks.Accounts.Guardian
  alias Stacks.Admin.SessionContext
  alias Stacks.Factory
  alias StacksWeb.Plugs.CsrfCookie
  alias StacksWeb.Plugs.SessionCookie

  @moduledoc """
      This module defines the test case to be used by
      tests that require setting up a connection.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import CoreWeb.ConnCase

      @endpoint CoreWeb.Endpoint
    end
  end

  setup tags do
    Core.DataCase.setup_sandbox(tags)
    {:ok, conn: proven_conn()}
  end

  @doc """
      A conn that can perform a state-changing request, i.e. one carrying the
      double-submit proof a browser would have.

      ⛔ **WHY THIS IS HERE AND NOT IN 475 TESTS.** Turning CSRF enforcement on
      broke 475 controller tests at once: `build_conn()` has no cookies, so
      every POST/PUT/PATCH/DELETE in the suite was refused. The alternative to
      this one change was editing each of them, or exempting the test
      environment — and exempting it would have left the gate untested in the
      only place it is ever run.

      ⚖️ So the suite now drives the PROVEN path by default, which is the path
      production uses. A test that wants to exercise an UNPROVEN request builds
      its conn with `Phoenix.ConnTest.build_conn()` directly and says so.

      ⚠️ The token value is arbitrary; what matters is that the cookie and the
      header agree, because that is the whole content of the check.
  """
  def proven_conn do
    token = "test-csrf-proof"

    Phoenix.ConnTest.build_conn()
    |> Plug.Test.put_req_cookie(CsrfCookie.cookie_name(), token)
    |> Plug.Conn.put_req_header("x-csrf-token", token)
  end

  @doc """
      Put a session on a conn the way a browser carries one: in the cookie.

      ⛔ **Use this rather than an `Authorization` header for anything that
      asserts about a BROWSER'S request.** The two transports are not
      interchangeable: `AuthPipeline` runs `SessionCookie` before
      `Guardian.Plug.VerifyHeader`, so the cookie WINS when both are present,
      and a test that authenticates by header is exercising the transport being
      retired rather than the one the reader uses.

      ⚠️ It matters most where a header is not available at all. `EventSource`
      cannot set one, which is why the upload stream used to take its credential
      from a `?token=` query parameter; a test of that route written with a
      header would pass while proving nothing about how a browser reaches it.
  """
  def with_session(conn, token) when is_binary(token) do
    Plug.Test.put_req_cookie(conn, SessionCookie.cookie_name(), token)
  end

  @doc """
      An elevated operator: an ordinary authenticated session, plus the
      MFA-verified admin session the server holds for that user.

      ⛔ THERE IS NO ADMIN CREDENTIAL ON THE CONN, and that absence is the
      point. Eight test files each built their own version of this, and every
      one of them minted a second Guardian token (`token_type: "admin"`,
      carrying `session_id`) and sent it as a Bearer — mirroring a client that
      held an admin token in memory, lost it on reload, and re-prompted for MFA
      the server had already recorded. Elevation is a fact about the session,
      so the conn carries only the ordinary session cookie and the elevation
      lives in `op.admin_sessions`.

      ⚠️ The IP must match what `StacksWeb.ClientIP.get/1` resolves for a test
      conn, because `SessionContext` stores a hash of it and refuses a
      mismatch. `Phoenix.ConnTest` gives `127.0.0.1`, which is what
      `SessionContext.create/3` is handed here — change one and the other has
      to move with it.

      Returns `{conn, user, admin_session}`.
  """
  def elevated_conn(conn, user \\ nil) do
    user = user || Factory.insert(:owner_user)

    {:ok, session} =
      SessionContext.create(user, "127.0.0.1", Core.Application.boot_id())

    {:ok, session} = SessionContext.mark_mfa_verified(session)
    {:ok, token, _} = Guardian.encode_and_sign(user)

    {with_session(conn, token), user, session}
  end
end
