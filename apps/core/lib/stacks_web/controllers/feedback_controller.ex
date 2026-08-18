defmodule StacksWeb.FeedbackController do
  @moduledoc """
      The reader's end of the beta feedback channel.

      The 201 response deliberately does NOT echo the submission back. Sending
      it again gives the client nothing it did not just type, and turns the
      response into a second copy of a free-text body in whatever logs the
      round trip passes through.
  """

  use CoreWeb, :controller

  import StacksWeb.ChangesetHelpers, only: [format_errors: 1]

  alias Stacks.Accounts.Guardian
  alias Stacks.Feedback

  @doc "POST /api/feedback"
  def create(conn, params) do
    user = Guardian.Plug.current_resource(conn)

    case Feedback.submit(user.id, params["body"], params["page_context"]) do
      {:ok, _entry} ->
        conn |> put_status(201) |> json(%{message: "received"})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{errors: format_errors(changeset)})
    end
  end
end
