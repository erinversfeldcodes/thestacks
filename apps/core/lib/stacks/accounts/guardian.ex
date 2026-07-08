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
      {:ok, claims}
    end
  end

  @impl true
  def verify_claims(claims, opts) do
    if claims["typ"] == "admin_session" do
      if claims["bid"] == Core.Application.boot_id() do
        super(claims, opts)
      else
        {:error, :invalid_boot_id}
      end
    else
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
