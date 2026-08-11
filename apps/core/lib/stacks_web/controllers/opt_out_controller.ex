defmodule StacksWeb.OptOutController do
  @moduledoc """
    Handles unauthenticated opt-out requests from businesses that have been
    discovered as sources.

    Businesses do not need a platform account to opt out — they provide
    their URL and a contact email, and the matching source is marked as excluded.
  """

  use CoreWeb, :controller

  alias Stacks.Discovery

  @doc """
    POST /api/opt-out — opt a discovered source out of the platform.

    Expects `%{"url" => url, "email" => email}`. Optionally accepts `"reason"`.
    Returns 200 on success, 404 if the URL is not found, 422 on validation error.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"url" => url, "email" => email} = _params) do
    case Discovery.opt_out(url, %{email: email}) do
      {:ok, :excluded, _source} ->
        json(conn, %{
          status: "removed",
          message: "Your listing has been removed and will not be re-added."
        })

      {:ok, :pending_review, _source} ->
        json(conn, %{
          status: "pending_review",
          message:
            "Your request has been received and will be reviewed. Because the contact " <>
              "address does not belong to the listed website's domain, we verify these " <>
              "by hand before removing a listing."
        })

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "No discovered source matches the provided URL."})

      {:error, :invalid_email} ->
        conn
        |> put_status(422)
        |> json(%{error: "The provided email address is not valid."})

      {:error, _changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: "Unable to process opt-out request."})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "url and email are required"})
  end
end
