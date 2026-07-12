defmodule Stacks.Accounts.Guardian do
  @moduledoc """
  Guardian implementation for JWT-based authentication.

  Supports two token types:
  - Standard user tokens (default `typ`)
  - Admin tokens (`typ: "admin_session"`) with additional `sid` (session_id) and
    `bid` (boot_id) claims. Admin tokens are rejected if the boot_id does not
    match the current application boot.
  """

  use Guardian, otp_app: :core

  alias Stacks.Accounts

  @impl true
  def subject_for_token(user, _claims) do
    {:ok, to_string(user.id)}
  end

  @impl true
  def resource_from_claims(%{"sub" => id}) do
    case Accounts.get_user(id) do
      nil -> {:error, :resource_not_found}
      user -> {:ok, user}
    end
  end

  def resource_from_claims(_), do: {:error, :invalid_claims}

  @impl true
  def build_claims(claims, _resource, opts) do
    if Keyword.get(opts, :token_type) == "admin" do
      {:ok,
       Map.merge(claims, %{
         "typ" => "admin_session",
         "sid" => Keyword.fetch!(opts, :session_id),
         "bid" => Keyword.fetch!(opts, :boot_id)
       })}
    else
      # Absolute session-lifetime anchor (Issue #179, Phase 1). Stamp "sst"
      # (session-start, unix seconds) at LOGIN so the cap can be measured from
      # the session's original issue. `Map.put_new/3` is load-bearing: Guardian
      # threads any claims passed to `encode_and_sign(user, %{"sst" => x})`
      # through the JWT builder BEFORE this hook (guardian.ex:601-602), so an
      # existing anchor is already present here and put_new PRESERVES it. This
      # is what lets refresh/2 carry the anchor forward across rotations without
      # it resetting on each renewal. Absent (fresh login) → stamped now.
      {:ok, Map.put_new(claims, "sst", System.system_time(:second))}
    end
  end

  @impl true
  def verify_claims(claims, opts) do
    cond do
      claims["typ"] == "admin_session" ->
        if claims["bid"] == Core.Application.boot_id() do
          super(claims, opts)
        else
          {:error, :invalid_boot_id}
        end

      is_binary(claims["family_id"]) ->
        # Reuse-detection gate (Issue #179, Phase 2b). Runs on EVERY authed
        # request. Ordering is load-bearing: in Guardian.decode_and_verify the
        # `mod.verify_claims` hook (deps/guardian/lib/guardian.ex:641) runs
        # BEFORE the guardian_db `on_verify` row-presence check (:642). So a
        # replayed already-rotated token — whose guardian_tokens row was deleted
        # on rotation — reaches HERE and is caught by the current_jti check,
        # triggering family revocation, instead of merely 401-ing opaquely at
        # on_verify with no chance to burn the family. One indexed PK lookup per
        # request; the revoke-write only fires on the reuse branch and is
        # idempotent + fails closed (never crashes the request).
        case Accounts.check_token_family(claims["family_id"], claims["jti"], claims["sub"]) do
          :ok -> {:ok, claims}
          {:error, _reason} = err -> err
        end

      true ->
        {:ok, claims}
    end
  end

  # ---------------------------------------------------------------------------
  # Server-side token revocation via Guardian.DB (Issue #124, A2)
  #
  # These hooks make `Guardian.revoke/1` and logout actually invalidate a token:
  # the token is persisted on sign, presence-checked on every verify, and deleted
  # on revoke. `token_types: ["access"]` in config means only regular user
  # sessions are tracked; admin_session tokens return `:ignore` and pass through
  # (they are revoked out-of-band via boot_id + the admin_sessions table).
  # ---------------------------------------------------------------------------

  @impl true
  def after_encode_and_sign(resource, claims, token, _opts) do
    with {:ok, _} <- Guardian.DB.after_encode_and_sign(resource, claims["typ"], claims, token) do
      {:ok, token}
    end
  end

  @impl true
  def on_verify(claims, token, _opts) do
    with {:ok, _} <- Guardian.DB.on_verify(claims, token) do
      {:ok, claims}
    end
  end

  @impl true
  def on_refresh({old_token, old_claims}, {new_token, new_claims}, _opts) do
    with {:ok, _, _} <-
           Guardian.DB.on_refresh({old_token, old_claims}, {new_token, new_claims}) do
      {:ok, {old_token, old_claims}, {new_token, new_claims}}
    end
  end

  @impl true
  def on_revoke(claims, token, _opts) do
    with {:ok, _} <- Guardian.DB.on_revoke(claims, token) do
      {:ok, claims}
    end
  end
end
