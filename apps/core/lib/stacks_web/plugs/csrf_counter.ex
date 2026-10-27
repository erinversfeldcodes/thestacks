defmodule StacksWeb.Plugs.CsrfCounter do
  @moduledoc """
      Counts whether a state-changing request could have proved itself — and
      refuses nothing.

      ## ⛔ Why a counter ships before enforcement, as its own change

      Turning a CSRF check on is the dangerous step, not adding the token. If
      any client path fails to send the header, enforcement rejects every write
      from it, and the symptom is "the site is broken" with no indication of
      which path or how many readers. The recorded lesson behind this issue is
      an enforcement that was switched on before the client side was converted.

      ⚖️ So this emits present / absent / mismatched for every unsafe request,
      and the decision to enforce becomes **a reading** rather than a judgement.
      A zero on `absent_header` over real traffic is the evidence; nothing else
      is.

      ⚠️ **This plug cannot reject.** Not "does not" — the module has no path
      that halts, which is the property that makes shipping it safe while the
      client rollout is still in doubt.

      ## ⛔ What this counter does NOT cover, which is the half a zero cannot tell you

      It is wired into the pipelines that carry browser traffic. It therefore
      says nothing about:

        * **`partner_auth` routes** (4 state-changing). Server-to-server, Argon2
          key, no cookie — they have no ambient authority to borrow and are not
          CSRF targets. Deliberately outside.
        * **`/api/test/*` helpers** (4). Gated behind `STACKS_E2E_TEST_HELPERS`
          and not reachable in production.

      ⚖️ So a zero here means "no browser request arrived without a proof on a
      route this plug saw". It does NOT mean "every state-changing route is
      proven". The scope is 83 of 91 state-changing routes, and that number is
      the thing to quote when reading the counter — a zero over a population you
      have not stated is the shape this project has twice mistaken for coverage.

      ## On comparing values

      The comparison is constant-time via `Plug.Crypto.secure_compare/2`. The
      token is not a secret, so this is not strictly required — but a
      non-constant-time compare on a value that is sometimes attacker-influenced
      is the kind of thing that becomes wrong when the surrounding assumptions
      change, and the cost here is nil.
  """

  import Plug.Conn

  alias StacksWeb.Plugs.CsrfCookie

  @header "x-csrf-token"
  @event [:stacks, :auth, :csrf_proof]

  # ⚠️ Safe methods are counted as `:safe` rather than skipped, so the series
  # carries a denominator. Without it, "absent_header is zero" and "this plug
  # never ran" produce the same empty result.
  @safe_methods ~w(GET HEAD OPTIONS)

  @doc "The header the SPA echoes the cookie in."
  def header_name, do: @header

  @doc "The telemetry event this plug emits."
  def event, do: @event

  def init(opts), do: opts

  def call(conn, _opts) do
    :telemetry.execute(@event, %{count: 1}, %{outcome: outcome(conn)})
    conn
  end

  @doc """
      How a request stands with respect to the double-submit proof.

      ⛔ The four outcomes are separate on purpose, and two of them look alike:
      `:absent_header` is a client that did not send the proof, `:absent_cookie`
      is a browser that never received one. The first is a client bug and the
      second is a server or cookie-attribute bug, and a single `:unproven` label
      would have made them indistinguishable in exactly the moment the
      distinction matters.

      ⚠️ `:mismatched` is listed separately from both because it is the only one
      consistent with an attack rather than a mistake.
  """
  def outcome(conn) do
    conn = fetch_cookies(conn)

    if String.upcase(conn.method) in @safe_methods do
      :safe
    else
      classify(
        conn |> get_req_header(@header) |> List.first(),
        conn.cookies[CsrfCookie.cookie_name()]
      )
    end
  end

  # ⚠️ The cookie is checked for emptiness as well as nil: an empty cookie and
  # an empty header would `secure_compare` as equal and read as a proof.
  defp classify(header, cookie)
       when is_binary(header) and header != "" and is_binary(cookie) and cookie != "" do
    if Plug.Crypto.secure_compare(header, cookie) do
      :proven
    else
      :mismatched
    end
  end

  defp classify(header, _cookie) when not is_binary(header) or header == "",
    do: :absent_header

  defp classify(_header, _cookie), do: :absent_cookie
end
