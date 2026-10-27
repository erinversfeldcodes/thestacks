defmodule StacksWeb.Plugs.CsrfCookie do
  @moduledoc """
      Issues the readable CSRF cookie the double-submit scheme echoes back.

      ## ⛔ Why this runs on the SPA's HTML response, not at login

      The obvious place to mint a CSRF token is where a session is minted. That
      is wrong here, and the failure is total rather than partial: `POST
      /api/auth/login` is itself a state-changing route with **no session yet**,
      so a token issued only at login means the login request has nothing to
      echo — and enforcement would reject every login attempt, on the one route
      nobody can work around.

      ⚖️ A browser cannot issue any XHR, the login POST included, before it has
      loaded the SPA's HTML. So setting the cookie on that response covers every
      subsequent request with no exemption and no ordering assumption about what
      the client does at boot. **That is a structural guarantee rather than a
      behavioural one**: the page load is not something the SPA chooses to do
      first, it is the precondition of the SPA existing.

      ⚠️ The alternative considered and rejected was exempting the pre-auth
      routes. It is cheaper and it leaves login fixation unaddressed while
      looking complete — a forged cross-site login can fixate a session whose
      credentials the attacker already knows, and that attack works precisely
      against a logged-out victim.

      ## ⛔ Deliberately NOT `HttpOnly`, and this will look like a mistake

      Every other cookie in this wave is `HttpOnly`. This one must not be: the
      SPA has to READ it in order to echo it in a header, and a token the client
      cannot read cannot be double-submitted. Making it `HttpOnly` would not
      fail loudly — it would silently stop the header being sent, and
      enforcement would then reject every write.

      ⚖️ It is safe to be readable because **it is not a secret**. It proves the
      request came from a document on our origin, which is exactly what a
      cross-site attacker cannot arrange: they can cause a request to be sent
      with the victim's cookies, but they cannot read the cookie to copy it into
      a header, because the same-origin policy stops them.

      ## On rotation

      The token is stable for the cookie's lifetime rather than per-request.
      Per-request rotation breaks concurrent requests and the back button, and
      buys nothing here: the proof is "you can read our cookie", not "you hold a
      value nobody has used before".
  """

  import Plug.Conn

  @cookie "stacks_csrf"

  # ⚠️ NOT `http_only`. See the module doc — the SPA has to read this one, and
  # the omission is the single most likely thing for a later reader to "fix".
  @cookie_opts [http_only: false, secure: true, same_site: "Lax"]

  # ⚠️ Longer than a session deliberately. The token is a same-origin proof, not
  # a credential, so expiring it with the session would log nobody out and would
  # instead leave a page open past expiry unable to write. 30 days.
  @max_age 60 * 60 * 24 * 30

  @doc "The cookie's name, so tests and the harness do not restate it."
  def cookie_name, do: @cookie

  @doc "How long an issued token lives, in seconds."
  def max_age, do: @max_age

  def init(opts), do: opts

  @doc """
      Sets the cookie when the request does not already carry one.

      ⚠️ Only when absent. Re-issuing on every page load would rotate the token
      out from under any other tab the reader has open, and the second tab's
      next write would be refused with no explanation.
  """
  def call(conn, _opts) do
    conn = fetch_cookies(conn)

    case conn.cookies[@cookie] do
      value when is_binary(value) and value != "" ->
        conn

      _ ->
        put_resp_cookie(conn, @cookie, generate_token(), @cookie_opts ++ [max_age: @max_age])
    end
  end

  @doc """
      A fresh token: 32 bytes of CSPRNG output, URL-safe base64, unpadded.

      ⚠️ `url_encode64` because the value travels in a header as well as a
      cookie, and a `+` or `/` in a header value is legal but invites
      double-encoding bugs at every layer that touches it.
  """
  def generate_token do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
