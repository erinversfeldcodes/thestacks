defmodule Stacks.Admin.SessionContext do
  @moduledoc """
      Context for managing admin sessions.

      Admin sessions are created when an owner logs in via the break-glass admin
      endpoint. They track IP address (hashed), boot ID, MFA verification status,
      expiry, and revocation. Sessions are bound to a single app boot — if the
      process restarts, all sessions from the previous boot become invalid.
  """

  import Ecto.Query

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
      nil -> {:error, :not_found}
      session -> check_valid(session, raw_ip)
    end
  end

  @doc """
      The operator's current admin session, found from the USER rather than from
      a session id the client supplied.

      ⛔ WHY THIS EXISTS. The admin pipeline used to locate the session via a
      `sid` claim inside a second Guardian token the SPA carried in memory.
      Nothing persisted that token, so a reload dropped it and re-prompted for
      MFA even though the server had already recorded the elevation. Elevation
      is a fact about the session the server holds, not a credential the client
      carries — so the lookup starts from the authenticated user.

      ⚖️ "The user's admin session" needs a rule, because an operator
      accumulates them over time. The rule is **the most recently created one
      that is still valid**, and validity is `check_valid/2` — the same five
      predicates `get_valid/2` applies, not a reimplementation of four of them.
      Candidates are narrowed in SQL on the cheap, indexable columns and the
      final judgement is made by the shared function, so a rule can never drift
      between the two entry points.

      ⚠️ The IP check stays, and stays via `ClientIP`: behind Fly the peer is
      the proxy's own address, and bare `remote_ip` produced spurious
      `:ip_mismatch` on the request after the password step. Callers pass the
      already-resolved client IP.
  """
  @spec current_for_user(binary(), String.t()) ::
          {:ok, AdminSession.t()}
          | {:error, :not_found | :revoked | :expired | :boot_id_mismatch | :ip_mismatch}
  def current_for_user(user_id, raw_ip) when is_binary(user_id) do
    now = DateTime.utc_now()

    AdminSession
    |> where([s], s.user_id == ^user_id)
    |> where([s], is_nil(s.revoked_at))
    |> where([s], s.expires_at > ^now)
    |> where([s], s.boot_id == ^Core.Application.boot_id())
    |> order_by([s], desc: s.created_at)
    |> limit(1)
    |> Repo.one(prefix: "op")
    |> case do
      nil -> {:error, :not_found}
      session -> check_valid(session, raw_ip)
    end
  end

  # The single judgement both entry points make. Ordered so the cheapest and
  # most-specific refusal wins: a revoked session should report `:revoked`
  # rather than whatever else is also true of it.
  defp check_valid(session, raw_ip) do
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
