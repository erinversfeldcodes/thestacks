defmodule StacksWeb.EmailVerificationController do
  @moduledoc """
      Handles email confirmation via signed token links.

      Every action here is unauthenticated: these are links clicked in a mail
      client, which carries no session. The token IS the credential, and it is
      checked twice — the signature must verify, and the token must still be the
      one stored on the row.

      All three actions answer in redirects, never JSON, because their reader is a
      person who clicked a link and needs a page. Every failure of every action
      lands on ONE page per flow: a dead link, an expired link, a link belonging to
      someone else and a change that was already settled are indistinguishable from
      outside, so none of them can be used to ask whether an address or an account
      exists.
  """

  use CoreWeb, :controller

  alias Stacks.Email

  @doc """
      GET /api/auth/confirm/:token — verify email confirmation token.

      Redirects to the frontend confirmation page rather than returning JSON,
      so users clicking the link from their email client see a proper UI.
  """
  def confirm(conn, %{"token" => token}) do
    case Email.confirm_email(token) do
      {:ok, _user} -> redirect_to_spa(conn, "/confirm-email/success")
      {:error, :invalid} -> redirect_to_spa(conn, "/confirm-email/error")
    end
  end

  @doc """
      GET /api/auth/confirm-email-change/:token — the new address proving itself.

      On success the pending address becomes the account's address and the change
      is settled, which also kills the undo link that was mailed to the old one.
  """
  def confirm_change(conn, %{"token" => token}) do
    case Email.confirm_email_change(token) do
      {:ok, _user} -> redirect_to_spa(conn, "/confirm-email/change-confirmed")
      {:error, :invalid} -> redirect_to_spa(conn, "/confirm-email/change-error")
    end
  end

  @doc """
      GET /api/auth/revert-email-change/:token — the old address saying no.

      Cancels the pending change, restores confirmed status, and revokes every
      session. The confirmation link mailed to the pending address stops working in
      the same write.
  """
  def revert_change(conn, %{"token" => token}) do
    case Email.revert_email_change(token) do
      {:ok, _user} -> redirect_to_spa(conn, "/confirm-email/change-reverted")
      {:error, :invalid} -> redirect_to_spa(conn, "/confirm-email/change-error")
    end
  end

  defp redirect_to_spa(conn, path) do
    redirect(conn, external: CoreWeb.Endpoint.url() <> path)
  end
end
