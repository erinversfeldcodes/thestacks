defmodule StacksWeb.UserSettingsController do
  @moduledoc "Handles user settings: age verification."

  use CoreWeb, :controller

  alias Stacks.Accounts
  alias Stacks.Accounts.Guardian

  @doc "PUT /api/settings/age_verification — set the age_verified flag for the current user."
  def update_age_verification(conn, %{"age_verified" => age_verified})
      when is_boolean(age_verified) do
    user = Guardian.Plug.current_resource(conn)

    case Accounts.update_age_verification(user.id, age_verified) do
      {:ok, updated_user} ->
        json(conn, %{age_verified: updated_user.age_verified})

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def update_age_verification(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "age_verified parameter is required and must be a boolean"})
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
