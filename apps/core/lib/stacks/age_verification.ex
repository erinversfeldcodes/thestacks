defmodule Stacks.AgeVerification do
  @moduledoc """
      Provider-sourced age verification — the SOLE writer of
      `age_verified`/`age_verified_at`/`age_verification_provider`.
      Self-declaration was removed; only a real KYC provider verifies.
      `record_verification/3` is the stable entry point a future provider
      webhook will call; today only tests and the flag-gated E2E helper
      exercise it (age-gating ships dark; production has no provider and no
      verified users). Every write emits `[:stacks,:age_verification]`.
  """

  require Logger

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Accounts.User

  @doc """
      Record a successful age verification for `user`, sourced from `provider`.

      Sets `age_verified: true`, `age_verified_at` (defaulting to now), and
      `age_verification_provider: provider`. Emits `[:stacks,:age_verification]`
      with `outcome::success` on success, `outcome::error` on changeset failure.

      Returns `{:ok, user}` or `{:error, changeset}`.
  """
  @spec record_verification(User.t(), String.t(), DateTime.t() | nil) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def record_verification(%User{} = user, provider, verified_at \\ nil)
      when is_binary(provider) do
    attrs = %{
      age_verified: true,
      age_verified_at: verified_at || DateTime.utc_now(),
      age_verification_provider: provider
    }

    user
    |> Accounts.verification_changeset(attrs)
    |> Repo.update()
    |> emit()
  end

  @doc """
      Clear a user's age verification (e.g. provider revocation). Sets
      `age_verified: false` and nulls the timestamp + provider. Emits the same
      telemetry family. Returns `{:ok, user}` or `{:error, changeset}`.
  """
  @spec revoke(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def revoke(%User{} = user) do
    attrs = %{age_verified: false, age_verified_at: nil, age_verification_provider: nil}

    user
    |> Accounts.verification_changeset(attrs)
    |> Repo.update()
    |> emit()
  end

  defp emit({:ok, _user} = result) do
    :telemetry.execute([:stacks, :age_verification], %{count: 1}, %{outcome: :success})
    result
  end

  defp emit({:error, _changeset} = result) do
    :telemetry.execute([:stacks, :age_verification], %{count: 1}, %{outcome: :error})
    result
  end
end
