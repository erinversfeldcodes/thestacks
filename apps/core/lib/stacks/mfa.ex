defmodule Stacks.MFA do
  @moduledoc """
  Context for TOTP-based Multi-Factor Authentication.

  Manages enrollment, verification, and disabling of TOTP MFA for users.
  Recovery codes are generated as 12-character uppercase hex strings and
  stored as SHA-256 hashes. TOTP secrets are encrypted at rest via
  `Stacks.EncryptedBinary`.
  """

  import Ecto.Query, warn: false

  alias Core.Repo
  alias Stacks.Accounts.User
  alias Stacks.MFA.UserMFA

  @issuer "The Stacks"
  @recovery_code_count 10

  # ---------------------------------------------------------------------------
  # Enrollment
  # ---------------------------------------------------------------------------

  @doc """
  Begin MFA enrollment for a user.

  Returns a map with:
  - `secret`: raw binary TOTP seed (not persisted yet)
  - `provisioning_uri`: otpauth:// URI for QR code display
  - `recovery_codes`: list of 10 plaintext recovery codes (one-time display)

  The caller must call `confirm_enrollment/4` after the user verifies the code.
  """
  @spec begin_enrollment(User.t()) ::
          {:ok, %{secret: binary(), provisioning_uri: String.t(), recovery_codes: [String.t()]}}
  def begin_enrollment(%User{} = user) do
    secret = NimbleTOTP.secret()
    uri = NimbleTOTP.otpauth_uri("#{@issuer}:#{user.email}", secret, issuer: @issuer)
    codes = generate_recovery_codes()
    {:ok, %{secret: secret, provisioning_uri: uri, recovery_codes: codes}}
  end

  @doc """
  Confirm MFA enrollment by verifying the TOTP code.

  If valid, persists the `UserMFA` record with hashed recovery codes and sets
  `enabled_at`. Uses upsert so re-enrollment replaces the existing record.

  Returns `{:ok, user_mfa}` or `{:error, :invalid_code}`.
  """
  @spec confirm_enrollment(User.t(), String.t(), binary(), [String.t()]) ::
          {:ok, UserMFA.t()} | {:error, :invalid_code}
  def confirm_enrollment(%User{} = user, totp_code, secret, recovery_codes)
      when is_binary(secret) do
    if NimbleTOTP.valid?(secret, totp_code) do
      hashed_codes = Enum.map(recovery_codes, &hash_code/1)

      attrs = %{
        user_id: user.id,
        totp_secret: secret,
        recovery_codes: hashed_codes,
        enabled_at: DateTime.utc_now()
      }

      changeset = UserMFA.changeset(%UserMFA{}, attrs)

      result =
        Repo.insert(changeset,
          on_conflict: {:replace_all_except, [:id, :created_at]},
          conflict_target: :user_id,
          returning: true,
          prefix: "op"
        )

      case result do
        {:ok, mfa} -> {:ok, mfa}
        {:error, _changeset} = err -> err
      end
    else
      {:error, :invalid_code}
    end
  end

  # ---------------------------------------------------------------------------
  # Verification
  # ---------------------------------------------------------------------------

  @doc """
  Verify a TOTP code for an enrolled user.

  Returns `:ok`, `{:error, :invalid_code}`, or `{:error, :not_enrolled}`.
  """
  @spec verify_totp(User.t(), String.t()) :: :ok | {:error, :not_enrolled | :invalid_code}
  def verify_totp(%User{} = user, code) do
    case get_user_mfa(user) do
      nil ->
        {:error, :not_enrolled}

      mfa ->
        if NimbleTOTP.valid?(mfa.totp_secret, code) do
          :ok
        else
          {:error, :invalid_code}
        end
    end
  end

  @doc """
  Verify a recovery code for an enrolled user.

  If valid, removes the code from the stored list so it cannot be reused.
  Returns `:ok`, `{:error, :invalid_code}`, or `{:error, :not_enrolled}`.
  """
  @spec verify_recovery_code(User.t(), String.t()) ::
          :ok | {:error, :not_enrolled | :invalid_code}
  def verify_recovery_code(%User{} = user, code) do
    case get_user_mfa(user) do
      nil ->
        {:error, :not_enrolled}

      mfa ->
        hashed = hash_code(code)

        if hashed in mfa.recovery_codes do
          consume_recovery_code(mfa, hashed)
        else
          {:error, :invalid_code}
        end
    end
  end

  @doc """
  Check whether a user has MFA enrolled.
  """
  @spec mfa_enabled?(User.t()) :: boolean()
  def mfa_enabled?(%User{} = user) do
    get_user_mfa(user) != nil
  end

  @doc """
  Disable MFA for a user after verifying their current TOTP code.

  Returns `:ok`, `{:error, :invalid_code}`, or `{:error, :not_enrolled}`.
  """
  @spec disable(User.t(), String.t()) :: :ok | {:error, :not_enrolled | :invalid_code}
  def disable(%User{} = user, totp_code) do
    case verify_totp(user, totp_code) do
      :ok ->
        user
        |> get_user_mfa()
        |> Repo.delete()

        :ok

      error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp consume_recovery_code(mfa, hashed) do
    remaining = List.delete(mfa.recovery_codes, hashed)

    case mfa |> Ecto.Changeset.change(recovery_codes: remaining) |> Repo.update() do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :update_failed}
    end
  end

  defp get_user_mfa(%User{id: user_id}) do
    UserMFA
    |> where([m], m.user_id == ^user_id)
    |> Repo.one()
  end

  defp generate_recovery_codes do
    for _ <- 1..@recovery_code_count do
      :crypto.strong_rand_bytes(6) |> Base.encode16(case: :upper)
    end
  end

  defp hash_code(code) do
    :crypto.hash(:sha256, code) |> Base.encode16(case: :lower)
  end
end
