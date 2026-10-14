defmodule StacksWeb.InviteController do
  @moduledoc """
      Public invitation lookup: `POST /api/auth/invite/check`.
      Deliberately absent from every payload: the owner's note, the bound
      email (even masked), and who redeemed — a valid guess must reveal
      nothing about a person (`email_bound` is a boolean so the form can say
      "written for a specific address" without naming it). Distinct statuses
      per failure mode are safe only because the code space is 128 bits and
      the shared `:auth` bucket caps guessing — the same budget as login,
      because code-guessing and password-guessing are the same attack.

      ⚠️ A POST, and the code travels in the BODY, for a lookup that reads
      naturally as a GET. The code is a credential: Phoenix logs
      `conn.request_path` at `:info` on every request, so a code in the path
      is a live credential written into the application log and anything that
      aggregates it — and into proxy logs and `Referer` headers besides.
      Nothing about the path form is filterable; the parameter form is, and
      `:filter_parameters` in `config.exs` does it. The code is typed into a
      form rather than arriving in a shared link, so no emailed URL depends on
      the old shape.
  """

  use CoreWeb, :controller

  alias Stacks.Accounts.Invites

  @doc ~S(POST /api/auth/invite/check — body `{"code": "…"}`.)
  def check(conn, params) do
    # A missing or blank code answers `invite_not_found` rather than 400: it is
    # the truthful answer (no invitation matches an empty string) and it tells a
    # prober nothing that distinguishing the two cases would.
    case Invites.check(to_string(params["code"] || "")) do
      {:ok, %{expires_at: expires_at, email_bound: email_bound}} ->
        json(conn, %{
          valid: true,
          expires_at: expires_at && DateTime.to_iso8601(expires_at),
          email_bound: email_bound
        })

      {:error, :invite_not_found} ->
        conn |> put_status(404) |> json(%{error: "invite_not_found"})

      {:error, :invite_expired} ->
        conn |> put_status(410) |> json(%{error: "invite_expired"})

      {:error, :invite_revoked} ->
        conn |> put_status(403) |> json(%{error: "invite_revoked"})

      {:error, :invite_exhausted} ->
        conn |> put_status(409) |> json(%{error: "invite_exhausted"})
    end
  end
end
