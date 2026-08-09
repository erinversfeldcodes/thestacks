defmodule StacksWeb.InviteController do
  @moduledoc """
  The public invitation lookup (US-14.1.3): `GET /api/auth/invite/:code`.

  Deliberately absent from every payload: the owner's note, the bound email
  (even masked), and the identity of anyone who has already redeemed. The code
  is a bearer secret; a valid guess must reveal nothing about a person.
  `email_bound` is a boolean so the form can say "this invitation was written
  for a specific address" without naming it.

  Distinct statuses per failure mode are safe only because the code space is
  128 bits behind the display prefix and the shared `:auth` rate bucket caps
  guessing — the same budget as login and password reset (#373), because a
  code-guessing sweep and a password-guessing sweep are the same attack
  against the same door.
  """

  use CoreWeb, :controller

  alias Stacks.Accounts.Invites

  @doc "GET /api/auth/invite/:code"
  def show(conn, %{"code" => code}) do
    case Invites.check(code) do
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
