defmodule Stacks.AgeVerification do
  @moduledoc """
  Provider-sourced age verification (ADR-020).

  This is the **sole writer** of the `age_verified` / `age_verified_at` /
  `age_verification_provider` columns. Self-declaration was removed as an
  unacceptable assurance mechanism; a viewer becomes age-verified only when a
  real identity/KYC provider says so.

  ## STUB

  `record_verification/3` is the stable entry point a future KYC-provider
  callback (Smile ID / Yoti / Sumsub) will call once a provider is integrated —
  the provider's webhook resolves the local user and calls this function with its
  own name and verification timestamp. Today it is exercised only by tests and
  the `STACKS_E2E_TEST_HELPERS`-gated E2E helper, so the full age-gate behaviour
  stays validated even though production has no provider and no verified users
  (age-gating is shipped dark — see `Stacks.FeatureFlags.age_gating_enabled?/0`).

  On every write it emits the `[:stacks, :age_verification]` telemetry family
  (repointed here from the deleted self-declared settings endpoint) with a
  whitelisted `:outcome` atom (`:success` / `:error`) and no PII — so the #230
  Grafana panel and the dashboard-drift guard stay green.
  """

  require Logger

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Accounts.User

  @doc """
  Record a successful age verification for `user`, sourced from `provider`.

  Sets `age_verified: true`, `age_verified_at` (defaulting to now), and
  `age_verification_provider: provider`. Emits `[:stacks, :age_verification]`
  with `outcome: :success` on success, `outcome: :error` on changeset failure.

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

  # Age-verification outcome counter (repointed from the removed self-declared
  # endpoint, ADR-020). `outcome` is a whitelisted atom — no user id, email, or
  # provider name in metadata (GDPR: telemetry is a warehouse-adjacent sink).
  defp emit({:ok, _user} = result) do
    :telemetry.execute([:stacks, :age_verification], %{count: 1}, %{outcome: :success})
    result
  end

  defp emit({:error, _changeset} = result) do
    :telemetry.execute([:stacks, :age_verification], %{count: 1}, %{outcome: :error})
    result
  end
end
