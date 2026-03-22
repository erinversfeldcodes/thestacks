defmodule CoreWeb.FallbackController do
  @moduledoc """
  Translates common `{:error, reason}` tuples from controller actions into
  appropriate HTTP responses.  Controllers opt in with `action_fallback/1`.
  """

  use CoreWeb, :controller

  import StacksWeb.ChangesetHelpers, only: [format_errors: 1]

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(422)
    |> json(%{errors: format_errors(changeset)})
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(404)
    |> json(%{error: "not_found"})
  end

  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(403)
    |> json(%{error: "forbidden"})
  end

  def call(conn, {:error, :invalid_transition}) do
    conn
    |> put_status(422)
    |> json(%{error: "invalid state transition"})
  end

  def call(conn, {:error, :no_placement}) do
    conn
    |> put_status(422)
    |> json(%{error: "you must own a placement of this book"})
  end

  def call(conn, {:error, :visibility_ceiling}) do
    conn
    |> put_status(422)
    |> json(%{error: "post visibility exceeds profile visibility ceiling"})
  end

  def call(conn, {:error, :placement_not_found}) do
    conn
    |> put_status(422)
    |> json(%{error: "placement not found"})
  end
end
