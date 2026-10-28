defmodule StacksWeb.UserSettingsController do
  @moduledoc """
      Handles user settings: profile, location, password, notifications, privacy.

      Age verification is NO LONGER a user-facing setting: self-declaration
      was removed as an unacceptable assurance mechanism. Verification is now
      provider-sourced via `Stacks.AgeVerification.record_verification/3`.
  """

  use CoreWeb, :controller

  import StacksWeb.ChangesetHelpers, only: [format_errors: 1]

  alias Stacks.Accounts
  alias Stacks.Accounts.Guardian
  alias Stacks.Shelving

  @doc """
      PUT /api/settings/profile — update display_name, website_url, and optionally
      email (requires current_password).

      `email` in the response is the address the account ANSWERS on, which an email
      change does not move: the new address is reported separately as
      `pending_email` until it confirms itself. A response that echoed the typed
      address back as `email` would tell the client the change had landed, and the
      settings form would settle on an address the account does not have.
  """
  def update_profile(conn, params) do
    user = Guardian.Plug.current_resource(conn)

    case Accounts.update_profile(user, params) do
      {:ok, updated} ->
        json(conn, %{
          display_name: updated.display_name,
          website_url: updated.website_url,
          email: updated.email,
          pending_email: updated.pending_email,
          handle: updated.handle,
          syndication_default: updated.syndication_default
        })

      {:error, :invalid_password} ->
        conn |> put_status(422) |> json(%{error: "invalid_current_password"})

      # The change could not be recorded because the two letters it is made of
      # could not be sent. Recording it anyway would leave a pending change nobody
      # holds a link to, so this is a refusal, not a partial success.
      # ⛔ THE LIMB IS NAMED, because the two mean opposite things to a caller
      # and a bare `email_rate_limited` forces it to guess. `per_user` is this
      # account sending too much — a refusal worth acting on. `global` is the
      # whole stack's hourly volume, and on a test stack the dominant source of
      # that is the SUITE ITSELF (a user per test, each queuing a confirmation),
      # so it says "the bucket is full", not "delivery is broken".
      #
      # ⚠️ Same reasoning as the two CSRF 403s, which carry a `reason` for
      # exactly this: a refusal a client cannot attribute gets attributed
      # wrongly. The deploy warmup's 403 was read as bad credentials for the
      # same lack.
      {:error, {:rate_limited, limb}} ->
        conn
        |> put_status(429)
        |> put_resp_header("retry-after", "3600")
        |> json(%{error: "email_rate_limited", limb: limb})

      {:error, :argon2_busy} ->
        conn
        |> put_status(503)
        |> put_resp_header("retry-after", "5")
        |> json(%{error: "service_busy"})

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
        Accounts.revoke_all_user_sessions(user.id)
        json(conn, %{ok: true})

      {:error, :invalid_password} ->
        conn |> put_status(422) |> json(%{error: "invalid_current_password"})

      {:error, :argon2_busy} ->
        conn
        |> put_status(503)
        |> put_resp_header("retry-after", "5")
        |> json(%{error: "service_busy"})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{errors: format_errors(changeset)})
    end
  end

  def update_password(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "current_password and new_password are required"})
  end

  @doc """
      GET /api/settings/notifications — return the current user's stored notification
      preferences so the settings screen hydrates from saved values instead of
      hardcoded defaults. Read-only: emits no event.
  """
  def show_notifications(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    json(conn, %{
      notify_wishlist_availability: user.notify_wishlist_availability,
      notify_marketplace: user.notify_marketplace,
      notify_group_invitations: user.notify_group_invitations,
      notify_event_matches: user.notify_event_matches
    })
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

  @doc """
      GET /api/settings/privacy — return the current user's profile visibility and
      their per-shelf visibilities so the privacy screen can seed saved values
      instead of hardcoded defaults.
  """
  def show_privacy(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    shelves =
      user.id
      |> Shelving.list_user_bookshelves()
      |> Enum.map(fn %{name: name, visibility: visibility} ->
        %{name: name, visibility: visibility}
      end)

    json(conn, %{
      profile_visibility: user.profile_visibility,
      shelves: shelves,
      consent_analytics: user.consent_analytics,
      consent_writing_assistant: user.consent_writing_assistant
    })
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
end
