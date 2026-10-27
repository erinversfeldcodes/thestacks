defmodule StacksWeb.Plugs.CsrfEnforce do
  @moduledoc """
      Refuses a state-changing request that cannot prove it came from a document
      on our origin.

      ## ⛔ What licensed turning this on

      Not a judgement — a reading. `StacksWeb.Plugs.CsrfCounter` shipped first
      and counted `proven / absent_header / absent_cookie / mismatched` over the
      deployed preview, and BOTH credential paths were then driven through the
      real client:

        * unauthenticated — `POST /api/auth/login`, three times, all `proven`;
        * authenticated — `PUT /api/settings/profile` and
          `PUT /api/settings/location`, each carrying
          `authorization | content-type | x-csrf-token` with the header matching
          the cookie.

      ⚠️ That sequence found a real defect before this plug existed: the proof
      was originally a field of the session credential, so a signed-OUT visitor
      had none and the login POST sent nothing. Had enforcement gone first, the
      symptom would have been every login on the site failing. The counter is
      the reason that did not happen, and it is why this module is a descendant
      of it rather than a sibling.

      ## The refusal is ATTRIBUTABLE, which is most of its value

      A bare `403 CSRF` turns a client bug into an afternoon. The four outcomes
      the counter already distinguishes are carried into the response:

        * `absent_header` — the client did not send the proof. A client bug.
        * `absent_cookie` — the browser never received one. A server or
          cookie-attribute bug, and a completely different fix.
        * `mismatched` — the only outcome consistent with an attack rather than
          a mistake.

      ⚠️ The reason is a BOUNDED atom, never free text and never anything from
      the request. An attacker-chosen string reflected into a response body is
      how a CSRF refusal becomes an injection surface.

      ## ⛔ What it does NOT protect, stated because a reader will assume otherwise

      It runs on the `:api` pipeline: **83 of 91** state-changing routes. The 4
      `partner_auth` routes carry an Argon2 key and no cookie — no ambient
      authority to borrow, so not CSRF targets — and the 4 `/api/test/*` helpers
      are unreachable in production. `scripts/check-csrf-scope.sh` holds those
      numbers to the router.

      ## On the token's value

      Compared with `Plug.Crypto.secure_compare/2`. The proof is not a secret,
      so constant time is not strictly required — but the comparison takes an
      attacker-influenced value, and a timing-variable compare on one of those
      is the kind of thing that becomes wrong when the surrounding assumptions
      change.
  """

  import Plug.Conn

  alias StacksWeb.Plugs.CsrfCounter

  @event [:stacks, :auth, :csrf_refused]

  @doc "The telemetry event emitted when a request is refused."
  def event, do: @event

  def init(opts), do: opts

  def call(conn, _opts) do
    case CsrfCounter.outcome(conn) do
      outcome when outcome in [:safe, :proven] ->
        conn

      reason ->
        :telemetry.execute(@event, %{count: 1}, %{reason: reason})

        conn
        |> put_status(:forbidden)
        |> Phoenix.Controller.json(%{
          error: "csrf_check_failed",
          reason: reason,
          detail: detail(reason)
        })
        |> halt()
    end
  end

  # ⚠️ Fixed strings chosen by `reason`, which is itself one of four atoms from
  # the counter. Nothing from the request reaches the response body.
  defp detail(:absent_header),
    do:
      "This request carried no X-CSRF-Token header. The value is in the readable " <>
        "stacks_csrf cookie and must be echoed in that header on every POST, PUT, " <>
        "PATCH and DELETE."

  defp detail(:absent_cookie),
    do:
      "No stacks_csrf cookie reached the server. It is issued on the page response; " <>
        "a client that calls the API without loading a page first must fetch one."

  defp detail(:mismatched),
    do: "The X-CSRF-Token header did not match the stacks_csrf cookie."

  defp detail(_), do: "This request could not prove its origin."
end
