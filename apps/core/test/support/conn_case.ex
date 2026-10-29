defmodule CoreWeb.ConnCase do
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
end
