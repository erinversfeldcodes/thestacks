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

  @doc "PUT /api/settings/profile — update display_name, website_url, and optionally email (requires current_password)."
  def update_profile(conn, params) do
    user = Guardian.Plug.current_resource(conn)

    case Accounts.update_profile(user, params) do
      {:ok, updated} ->
        json(conn, %{
          display_name: updated.display_name,
          website_url: updated.website_url,
          email: updated.email
        })

      {:error, :invalid_password} ->
        conn |> put_status(422) |> json(%{error: "invalid_current_password"})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{errors: format_errors(changeset)})
    end
  end

  @doc "PUT /api/settings/location — update country_code and city."
  def update_location(conn, params) do
    user = Guardian.Plug.current_resource(conn)

    case Accounts.update_location(user, params) do
      {:ok, updated} ->
        json(conn, %{country_code: updated.country_code, city: updated.city})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{errors: format_errors(changeset)})
    end
  end

  @doc "PUT /api/settings/password — change password (requires current_password + new_password)."
  def update_password(conn, %{"current_password" => current, "new_password" => new_pw}) do
    user = Guardian.Plug.current_resource(conn)

    case Accounts.change_password(user, current, new_pw) do
      {:ok, _} ->
        json(conn, %{ok: true})

      {:error, :invalid_password} ->
        conn |> put_status(422) |> json(%{error: "invalid_current_password"})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{errors: format_errors(changeset)})
    end
  end

  def update_password(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "current_password and new_password are required"})
  end

  @doc "PUT /api/settings/notifications — toggle notification preferences."
  def update_notifications(conn, params) do
    user = Guardian.Plug.current_resource(conn)

    case Accounts.update_notifications(user, params) do
      {:ok, updated} ->
        json(conn, %{
          notify_wishlist_availability: updated.notify_wishlist_availability,
          notify_marketplace: updated.notify_marketplace,
          notify_group_invitations: updated.notify_group_invitations,
          notify_event_matches: updated.notify_event_matches
        })

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{errors: format_errors(changeset)})
    end
  end

  @doc "PUT /api/settings/profile_visibility — set the profile_visibility for the current user."
  def update_profile_visibility(conn, %{"profile_visibility" => visibility}) do
    user = Guardian.Plug.current_resource(conn)

    case Accounts.update_profile_visibility(user.id, visibility) do
      {:ok, updated_user} ->
        json(conn, %{profile_visibility: updated_user.profile_visibility})

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def update_profile_visibility(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "profile_visibility parameter is required"})
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
