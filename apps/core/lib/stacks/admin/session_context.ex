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
      Create a new admin session for the given user, retiring any other live one.

      The IP address is SHA-256 hashed before storage (same convention as `audit_log`).
      The session expires 30 minutes from creation.

      ⛔ **ONE LIVE ADMIN SESSION PER OPERATOR, and the revocation is the point.**
      Elevating somewhere new revokes the elevation everywhere else, in the same
      transaction. That is a deliberate policy, not a side effect:

        * an operator who elevates on a borrowed machine and walks away used to
          leave a live, MFA-verified admin session in this table for up to
          #{@session_ttl_minutes} minutes, and nothing retired it — elevating
          again elsewhere merely out-sorted it in one query's `ORDER BY`;
        * it makes "the operator's admin session" a question with one answer, so
          `current_for_user/2` has no selection rule to get wrong;
        * it kills the row, not just one lookup path's view of it, so the
          guarantee survives a second caller being added later.

      ⚖️ The cost is that an operator working from two machines at once is
      bounced from the first — accepted, because this platform has one operator,
      and the alternative is leaving a credential alive on a machine they have
      walked away from.
  """
  @spec create(User.t(), String.t(), String.t()) :: {:ok, AdminSession.t()} | {:error, any()}
  def create(%User{} = user, raw_ip, boot_id) do
    Repo.transaction(fn ->
      retire_live_sessions(user.id)

      case insert_session(user, raw_ip, boot_id) do
        {:ok, session} -> session
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
      Revoke every live admin session an operator holds, returning how many.

      The same statement `create/3` runs, exposed because an E2E run needs to
      put the operator back to "not elevated" deterministically — and because
      revoking is the one operation on this table that can only ever reduce
      access, so a caller cannot use it to grant anything.
  """
  @spec revoke_all_for_user(binary()) :: non_neg_integer()
  def revoke_all_for_user(user_id) when is_binary(user_id) do
    {count, _} = retire_live_sessions(user_id)
    count
  end

  # Everything still usable: unrevoked. Expired and wrong-boot rows are already
  # dead and rewriting them would only churn the table.
  defp retire_live_sessions(user_id) do
    Repo.update_all(
      from(s in AdminSession, where: s.user_id == ^user_id and is_nil(s.revoked_at)),
      [set: [revoked_at: DateTime.utc_now()]],
      prefix: "op"
    )
  end

  defp insert_session(user, raw_ip, boot_id) do
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
      The operator's current admin session, found from the USER rather than from
      a session id the client supplied.

      ⛔ WHY THIS EXISTS. The admin pipeline used to locate the session via a
      `sid` claim inside a second Guardian token the SPA carried in memory.
      Nothing persisted that token, so a reload dropped it and re-prompted for
      MFA even though the server had already recorded the elevation. Elevation
      is a fact about the session the server holds, not a credential the client
      carries — so the lookup starts from the authenticated user.

      ⚖️ **There is no selection rule, and that is deliberate.** `create/3`
      revokes the operator's other live sessions, so at most one is unrevoked at
      any moment — the question "which of the operator's admin sessions?" has
      one answer by construction rather than by an `ORDER BY` somebody has to
      get right. An earlier version picked the most recently *created* candidate
      and judged it afterwards, which meant a newer session from another network
      made the caller's own valid session unreachable: a measured
      `:ip_mismatch` for an operator holding a perfectly good credential, which
      is the re-prompt this whole change exists to remove.

      ⛔ **The SQL selects; `check_valid/2` judges. No predicate appears in
      both.** `revoked_at` is in the query because revocation is how the live
      session is *identified* among an operator's retired ones — not a validity
      rule. Expiry, `boot_id` and the IP are validity, and are deliberately NOT
      in the query: when expiry and `boot_id` were in both, a change to
      `check_valid/2` silently did not apply here because the row had already
      been filtered out — measured, with two entry points then disagreeing
      about the same session.

      ⚠️ So a revoked-only operator gets `:not_found`, which is the honest
      answer: they have no live elevation. And an operator whose live elevation
      belongs to a different location gets `:ip_mismatch` — a true statement
      about a stated policy, where before it was an accident of `ORDER BY`.

      ⚠️ The IP check stays, and stays via `ClientIP`: behind Fly the peer is
      the proxy's own address, and bare `remote_ip` produced spurious
      `:ip_mismatch` on the request after the password step. Callers pass the
      already-resolved client IP.
  """
  @spec current_for_user(binary(), String.t()) ::
          {:ok, AdminSession.t()}
          | {:error, :not_found | :expired | :boot_id_mismatch | :ip_mismatch}
  def current_for_user(user_id, raw_ip) when is_binary(user_id) do
    AdminSession
    |> where([s], s.user_id == ^user_id)
    |> where([s], is_nil(s.revoked_at))
    |> order_by([s], desc: s.created_at)
    |> limit(1)
    |> Repo.one(prefix: "op")
    |> case do
      nil -> {:error, :not_found}
      session -> check_valid(session, raw_ip)
    end
  end

  # The one judgement, and every predicate in it lives ONLY here.
  #
  # ⚠️ There is deliberately no `revoked_at` arm. Revocation is how
  # `current_for_user/2` SELECTS the live session — a retired row is not a
  # session that fails validation, it is not the operator's session at all — so
  # an arm here would be unreachable from the only caller, and unreachable code
  # that looks like a safety check is worse than no check.
  defp check_valid(session, raw_ip) do
    cond do
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
