defmodule Stacks.Admin.SessionContext do
  @moduledoc """
      Context for managing admin sessions.

      Admin sessions are created when an owner logs in via the break-glass admin
      endpoint. They track IP address (hashed), boot ID, MFA verification status,
      expiry, and revocation. Sessions are bound to a single app boot — if the
      process restarts, all sessions from the previous boot become invalid.
  """

  alias Core.Repo
  alias Stacks.Accounts.User
  alias Stacks.AdminSession

  @session_ttl_minutes 30

  @doc """
      Create a new admin session for the given user.

      The IP address is SHA-256 hashed before storage (same convention as `audit_log`).
      The session expires 30 minutes from creation.
  """
  @spec create(User.t(), String.t(), String.t()) :: {:ok, AdminSession.t()} | {:error, any()}
  def create(%User{} = user, raw_ip, boot_id) do
    attrs = %{
      user_id: user.id,
      ip_hash: hash_ip(raw_ip),
      boot_id: boot_id,
      expires_at: DateTime.add(DateTime.utc_now(), @session_ttl_minutes, :minute)
    }

    %AdminSession{}
    |> Ecto.Changeset.cast(attrs, [:user_id, :ip_hash, :boot_id, :expires_at])
    |> Ecto.Changeset.validate_required([:user_id, :ip_hash, :boot_id, :expires_at])
    |> Repo.insert(prefix: "op")
  end

  @doc """
      Mark MFA as verified on the session by setting `mfa_verified_at` to now.
  """
  @spec mark_mfa_verified(AdminSession.t()) :: {:ok, AdminSession.t()} | {:error, any()}
  def mark_mfa_verified(%AdminSession{} = session) do
    session
    |> Ecto.Changeset.change(mfa_verified_at: DateTime.utc_now())
    |> Repo.update()
  end

  @doc """
      Load and validate a session by ID and client IP.

      Returns `{:ok, session}` if the session is valid, or one of:
      - `{:error,:not_found}` — no session with that ID
      - `{:error,:revoked}` — session has been explicitly revoked
      - `{:error,:expired}` — session has passed its `expires_at`
      - `{:error,:boot_id_mismatch}` — session was created by a different app boot
      - `{:error,:ip_mismatch}` — request IP does not match the session's stored hash
  """
  @spec get_valid(String.t(), String.t()) ::
          {:ok, AdminSession.t()}
          | {:error, :not_found | :revoked | :expired | :boot_id_mismatch | :ip_mismatch}
  def get_valid(session_id, raw_ip) do
    case Repo.get(AdminSession, session_id, prefix: "op") do
      nil ->
        {:error, :not_found}

      session ->
        cond do
          session.revoked_at != nil ->
            {:error, :revoked}

          DateTime.compare(session.expires_at, DateTime.utc_now()) == :lt ->
            {:error, :expired}

          session.boot_id != Core.Application.boot_id() ->
            {:error, :boot_id_mismatch}

          hash_ip(raw_ip) != session.ip_hash ->
            {:error, :ip_mismatch}

          true ->
            {:ok, session}
        end
    end
  end

  @doc """
      Revoke a session by setting `revoked_at` to now.
  """
  @spec revoke(AdminSession.t()) :: {:ok, AdminSession.t()} | {:error, any()}
  def revoke(%AdminSession{} = session) do
    session
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
    |> Repo.update()
  end

  defp hash_ip(raw_ip), do: Stacks.IPDigest.hash(raw_ip)
end
