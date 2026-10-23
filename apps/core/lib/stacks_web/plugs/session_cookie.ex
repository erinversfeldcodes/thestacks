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

      ## ⛔ WHAT THE COUNTER DOES NOT COVER — read this before deleting anything

      This plug sits in `AuthPipeline` only, and the counter is registered
      inside it, so **a pipeline that does not include this plug emits
      nothing at all.** Measured 2026-10-23, four pipelines authenticate:

        * `AuthPipeline` — cookie or Bearer header. **Counted.**
        * `AdminAuthPipeline` — Bearer header, `admin_session` type. NOT counted.
        * `OptionalAuthPipeline` — Bearer header, `allow_blank: true`. NOT counted.
        * `SseAuthPipeline` — JWT in the `?token=` QUERY PARAMETER. NOT counted.

      ⛔ So "the bearer series reads zero" means *zero bearer-authenticated
      requests through the user-session pipeline* — and three other pipelines
      read bearer tokens whose use is invisible here. Deleting bearer support
      repository-wide on this reading would break the admin console, every
      optional-auth page and the SSE stream. The admin and SSE transports move
      with their own pipelines, each of which must bring its own measurement.

      ⚠️ And a narrower exclusion inside the counted pipeline: only requests
      that AUTHENTICATE are counted, so **zero authenticated bearer requests is
      not zero bearer attempts.** A client whose tokens all fail is invisible
      here, which means the zero can coexist with something still trying to use
      bearer — a token-rotation window, say. Deleting the path then breaks a
      client that was reaching for it.
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
  # ⛔ `SameSite=Lax` IS THE CSRF MITIGATION UNTIL THE DOUBLE-SUBMIT TOKEN LANDS,
  # so the standard question when cookie auth arrives has to be answered rather
  # than inferred: **Lax still sends the cookie on top-level GET navigation, so
  # is any state-changing route a GET?**
  #
  # MEASURED 2026-10-23 across the whole router — 69 GET routes, of which THREE
  # reach a state-changing action:
  #
  #   GET /auth/confirm/:token              EmailVerification.confirm
  #   GET /auth/confirm-email-change/:token EmailVerification.confirm_change
  #   GET /confirmation-token               TestHelper.confirmation_token
  #
  # ⚖️ All three are authorised by a CAPABILITY TOKEN IN THE PATH rather than by
  # the session, so a Lax-sent session cookie confers no authority on them — a
  # cross-site GET to a confirmation URL succeeds or fails on whether the
  # attacker holds the token, exactly as it did before cookies existed. The
  # third is additionally behind the E2E-helper env gate.
  #
  # ⛔ AND THE OTHER HALF, which is the one the cookie actually turns on. The
  # three routes above are authorised by a PATH token, which is the safe case;
  # the dangerous case is a GET authorised BY THE SESSION that mutates. Measured
  # 23 session-authorised GETs behind the `:authenticated` pipeline, and all 23
  # are reads:
  #
  #   /listings/mine · /uploads/inbox · /auth/me · /books/isbn/:isbn
  #   /imports · /imports/:id · /imports/:id/rows · /placements/mine
  #   /bookshelves/:bookshelf_name · /bookshelves/:bookshelf_name/shelves
  #   /bookshelves/:bookshelf_id/grants · /onboarding/status · /me/inferences
  #   /settings/privacy · /settings/notifications · /settings/blocked-users
  #   /settings/audit-log · /posts/:post_id/comments · /groups/:id
  #   /groups/:id/feed · /groups/:group_id/members
  #   /blog/posts/:id/syndication · /blog/posts/:id/syndications
  #
  # ⚠️ `/books/isbn/:isbn` is the one that looks like it might write — an ISBN
  # lookup that resolves and inserts would be a state-changing GET. Checked: it
  # is `Books.find_existing/1` plus a 404, with no resolver call and no insert,
  # so an unknown ISBN creates nothing.
  #
  # ⚖️ **THE SET IS NAMED ON PURPOSE.** "No state-changing GET" is a claim over a
  # POPULATION, and listing the population is what makes it re-CHECKABLE rather
  # than re-DERIVABLE — the next reader can diff this list against the router
  # instead of repeating the analysis and hoping they used the same predicate.
  #
  # ⚠️ The next person to add a GET that acts on `current_resource` re-opens
  # this, and nothing here would notice. That is the standing hazard; the list
  # above is what makes noticing cheap.
  @cookie_opts [http_only: true, secure: true, same_site: "Lax"]

  @transport_event [:stacks, :auth, :session_transport]
  @cookie_rejected_event [:stacks, :auth, :session_cookie_rejected]

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
         %{@cookie => token} when is_binary(token) and token != "" <- conn.cookies do
      verify_cookie(conn, opts, token)
    else
      _ -> conn
    end
  end

  # ⛔ A PRESENT-BUT-UNUSABLE COOKIE IS COUNTED SEPARATELY, because the transport
  # counter cannot distinguish it from no cookie at all.
  #
  # Both states fall through to the bearer path and both are therefore counted
  # `:bearer`. During a migration that is the EXPECTED initial reading — so a
  # systemic cookie failure (a key rotation, or the documented case where
  # binding dev beyond loopback stops `Secure` cookies being sent at all)
  # presents as "the rollout has not started yet" and nothing says otherwise.
  #
  # ⚖️ A separate counter rather than a transport tag, deliberately. The
  # transport series answers "which transport is carrying sessions", which is
  # the bearer-DELETION question, and adding failures to it would corrupt that
  # reading. "Is the cookie transport working" is a different question and needs
  # the failures the other counter correctly excludes. Observability only — no
  # semantics change, and the fall-through below is byte-identical to before.
  defp verify_cookie(conn, opts, token) do
    module = Pipeline.fetch_module!(conn, opts)
    key = Pipeline.fetch_key(conn, opts)
    verify_opts = Guardian.Plug.resolve_secret(conn, opts)

    case Guardian.decode_and_verify(module, token, %{}, verify_opts) do
      {:ok, claims} ->
        conn
        |> Guardian.Plug.put_current_token(token, key: key)
        |> Guardian.Plug.put_current_claims(claims, key: key)
        |> put_private(:stacks_session_transport, :cookie)

      {:error, reason} ->
        # ⚠️ The reason is bounded to the atom Guardian returns, and anything
        # else is collapsed to `:other`. An unbounded label on a counter is a
        # cardinality leak, and this one is fed by a value a client controls.
        :telemetry.execute(@cookie_rejected_event, %{count: 1}, %{reason: reject_label(reason)})
        conn
    end
  end

  @known_rejections [
    :invalid_token,
    :token_expired,
    :invalid_issuer,
    :invalid_audience,
    :not_found
  ]

  @doc """
      Collapses a Guardian rejection to a bounded counter label.

      ⛔ PUBLIC FOR ONE REASON: the `:other` fallback is otherwise UNTESTABLE,
      and it is the clause that matters.

      MEASURED — a probe making the mapping unbounded left the suite fully
      green, because every reason reachable through an HTTP request lands in
      the known list, so no request-driven test can tell a bounded mapping from
      an unbounded one. The fallback exists for a reason Guardian has not
      returned yet, which is precisely the input no request can produce.

      ⚠️ And the bound is not tidiness: this label is fed by a value a client
      controls, so unbounded means a metric-cardinality leak. A guard whose only
      untested clause is the security-relevant one is the wrong way round.
  """
  @spec reject_label(term()) :: atom()
  def reject_label(reason) when reason in @known_rejections, do: reason
  def reject_label({reason, _detail}) when reason in @known_rejections, do: reason
  def reject_label(_), do: :other

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
