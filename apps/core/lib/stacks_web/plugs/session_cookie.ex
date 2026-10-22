defmodule StacksWeb.Plugs.SessionCookie do
  @moduledoc """
      Accepts a session carried by cookie, and counts which transport carried it.

      ⛔ WHY A PLUG OF OUR OWN RATHER THAN GUARDIAN'S. Two of Guardian's three
      candidates are wrong here and the reasons are worth recording, because the
      obvious next edit is to replace this with one of them:

        * `Guardian.Plug.VerifySession` reads the token out of `Plug.Session` —
          the cookie session store this change DELETES. It cannot be used.
        * `Guardian.Plug.VerifyCookie` is deprecated in Guardian 2.5 and
          performs a token EXCHANGE: it expects a long-lived `refresh` cookie
          and swaps it for an `access` token. That is a different design from
          the one decided — here the cookie carries the same session token the
          bearer header carried, so the transport changes and nothing else
          does. Using it would quietly introduce a refresh-token scheme.

      ⚖️ WHERE THIS SITS AND WHY THE ORDER IS LOAD-BEARING. It runs BEFORE
      `Guardian.Plug.VerifyHeader`, whose `call/2` opens with
      `with nil <- Guardian.Plug.current_token(conn, opts)` — so a token already
      on the conn makes it a no-op. That is what gives both transports for one
      release without a branch: cookie wins when present, the bearer header is
      found when it is not, and neither path knows about the other.

      ⚠️ PROBED RATHER THAN ASSERTED, and the first version of this comment
      overstated it. Reversing the two plugs reds exactly ONE test — "the cookie
      is what authenticates, and the count says so". The cookie-only path keeps
      working, because `VerifyHeader` with no header present does not refuse; it
      falls through and this plug still finds the cookie.
      ⛔ So what the order protects is narrower and worth stating exactly: the
      PRECEDENCE when a client sends BOTH, and therefore the counter's reading
      in the mixed case — which is the case the whole rollout turns on, since a
      mid-migration client is precisely the one sending both. One test stands
      between a reversed order and a bearer series that reads zero while the
      bearer path carries traffic.

      ## The counter is the point, not a decoration

      The rollout deletes the bearer path on EVIDENCE rather than on judgement,
      and this counter is that evidence. It emits
      `[:stacks, :auth, :session_transport]` tagged `:cookie` or `:bearer`.

      ⛔ It counts only requests that AUTHENTICATED. An unauthenticated request
      offers a transport too, and counting those would mean "the bearer series
      is at zero" could be satisfied by a stream of failures. The question the
      deletion needs answered is which transport is carrying real sessions.

      ⚠️ Emitted from `register_before_send/2` rather than inline, because the
      answer is not known at this point in the pipeline: whether the token this
      plug found is VALID is decided later by `EnsureAuthenticated` and
      `LoadResource`. Emitting inline would count an expired cookie as a live
      cookie session.
  """

  @behaviour Plug

  import Plug.Conn

  alias Guardian.Plug.Pipeline

  # ⛔ The cookie's name, decided here because the ADR records the attributes and
  # not the name, and the repository had no cookie of any kind to follow.
  #
  # ⚖️ `__Host-` was considered and DECLINED. It is a real improvement in
  # general — the prefix forces `Secure`, forbids `Domain`, and pins `Path=/`,
  # which closes subdomain cookie-setting. Declined for two measured reasons:
  # this deployment serves one host, so the subdomain attack it prevents has no
  # surface here; and browser handling of `__Host-` over `http://localhost` is
  # less uniformly implemented than plain `Secure`, which would stack a SECOND
  # localhost-dependent behaviour on top of the one the `secure: true` ruling
  # already relies on. One such dependency, understood and commented, is better
  # than two.
  @cookie "stacks_session"

  # ⚠️ `Secure` is unconditional, and that is a ruling rather than an oversight.
  # Measured: dev and test bind `127.0.0.1` ONLY, every local E2E URL is
  # `http://localhost`, and production is HTTPS — and browsers accept `Secure`
  # cookies on localhost. A config flag was considered and declined because the
  # scenario it would serve (reaching dev over a LAN IP) is unreachable while
  # nothing binds beyond loopback.
  #
  # ⛔ TWO COUPLINGS, because a flag would have let either be configured away
  # instead of understood:
  #
  #   1. Binding dev to `0.0.0.0` to reach it from another device stops these
  #      cookies being sent, and development login then fails SILENTLY.
  #   2. Adding a WebKit or Firefox E2E project re-opens the question: the
  #      localhost exemption is implemented across browsers but not
  #      identically, and every Playwright project here is Desktop Chrome.
  @cookie_opts [http_only: true, secure: true, same_site: "Lax"]

  @transport_event [:stacks, :auth, :session_transport]

  @doc "The cookie's name, for the controllers that set and clear it."
  @spec cookie_name() :: String.t()
  def cookie_name, do: @cookie

  @doc """
      Writes the session cookie. Called by whatever issues a session.

      ⚠️ `max_age` rather than a bare session cookie: the session must survive a
      browser restart, which is the user-visible claim the transport exists to
      make. The value tracks the token's own lifetime so the cookie does not
      outlive what it carries.
  """
  @spec put_session_cookie(Plug.Conn.t(), String.t(), pos_integer()) :: Plug.Conn.t()
  def put_session_cookie(conn, token, max_age) when is_binary(token) and is_integer(max_age) do
    put_resp_cookie(conn, @cookie, token, Keyword.put(@cookie_opts, :max_age, max_age))
  end

  @doc """
      Clears the session cookie. Called on logout.

      ⚠️ The same attributes are passed on deletion, not just the name. A cookie
      is identified by name plus path plus domain, so clearing it with different
      attributes leaves the original in place — which would read as a logout
      that worked while the session kept being replayed.
  """
  @spec delete_session_cookie(Plug.Conn.t()) :: Plug.Conn.t()
  def delete_session_cookie(conn) do
    delete_resp_cookie(conn, @cookie, Keyword.delete(@cookie_opts, :max_age))
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    conn = fetch_cookies(conn)

    conn
    |> adopt_cookie_token(opts)
    |> register_before_send(&count_transport/1)
  end

  # ⛔ THE TOKEN IS VERIFIED HERE, NOT MERELY STORED, and the first version of
  # this plug got that wrong in the direction that matters.
  #
  # It called `put_current_token/3` and stopped. `EnsureAuthenticated` checks
  # CLAIMS rather than the token, so every cookie request 401'd — which is how
  # the mistake surfaced. ⚠️ But the 401 was luck: had `EnsureAuthenticated`
  # keyed on token presence, an unverified cookie value would have authenticated
  # the request. A plug that puts a credential on the conn without verifying it
  # is one `with` clause away from being an authentication bypass.
  #
  # So this mirrors `VerifyHeader`'s own sequence — fetch the module, resolve
  # the secret, `decode_and_verify`, then store token AND claims under the
  # pipeline's key — and differs from it in exactly one respect: where the token
  # comes from.
  #
  # ⚖️ A decode failure falls through to `conn` UNCHANGED rather than to the
  # error handler, which is deliberate and is the whole both-transports
  # mechanism: a stale cookie must not refuse a request that also carries a live
  # bearer header. `VerifyHeader` runs next and will find it; if there is no
  # header either, `EnsureAuthenticated` refuses, which is the correct 401 from
  # the correct plug. Calling the error handler here would make a junk cookie
  # fatal and break the migration for every client that holds one.
  defp adopt_cookie_token(conn, opts) do
    with nil <- Guardian.Plug.current_token(conn, opts),
         %{@cookie => token} when is_binary(token) and token != "" <- conn.cookies,
         module <- Pipeline.fetch_module!(conn, opts),
         key <- Pipeline.fetch_key(conn, opts),
         verify_opts <- Guardian.Plug.resolve_secret(conn, opts),
         {:ok, claims} <- Guardian.decode_and_verify(module, token, %{}, verify_opts) do
      conn
      |> Guardian.Plug.put_current_token(token, key: key)
      |> Guardian.Plug.put_current_claims(claims, key: key)
      |> put_private(:stacks_session_transport, :cookie)
    else
      _ -> conn
    end
  end

  # ⛔ The transport is read from `conn.private`, not re-derived from the request
  # here. Re-deriving would ask "is a cookie present?" at response time, which
  # is a different question from "did the cookie supply the token that
  # authenticated this request" — a request carrying both a stale cookie and a
  # live bearer header would be counted as `:cookie` and the bearer series would
  # read zero while the bearer path was the only thing working.
  defp count_transport(conn) do
    if Guardian.Plug.current_resource(conn) do
      transport = Map.get(conn.private, :stacks_session_transport, :bearer)
      :telemetry.execute(@transport_event, %{count: 1}, %{transport: transport})
    end

    conn
  end
end
