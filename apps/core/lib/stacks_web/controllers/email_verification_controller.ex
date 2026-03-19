defmodule StacksWeb.EmailVerificationController do
  @moduledoc "Handles email confirmation via signed token links."

  use CoreWeb, :controller

  alias Stacks.Email

  @doc """
  GET /api/auth/confirm/:token — verify email confirmation token.

  Redirects to the frontend confirmation page rather than returning JSON,
  so users clicking the link from their email client see a proper UI.
  """
  def confirm(conn, %{"token" => token}) do
    base_url = CoreWeb.Endpoint.url()

    case Email.confirm_email(token) do
      {:ok, _user} ->
        redirect(conn, external: base_url <> "/confirm-email/success")

      {:error, :invalid} ->
        redirect(conn, external: base_url <> "/confirm-email/error")
    end
  end
end
