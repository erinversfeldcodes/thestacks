defmodule Stacks.GDPR.Consent do
  @moduledoc """
  GDPR consent management. Handles granting, revoking, and checking user consent
  for analytics data collection. Consent timestamps are always recorded.
  """

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Accounts.User

  @doc """
  Grants analytics consent for a user. Records the timestamp of consent.
  """
  @spec grant_consent(binary(), String.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def grant_consent(user_id, feature \\ "analytics") do
    user = Accounts.get_user!(user_id)
    now = DateTime.utc_now()

    user
    |> Accounts.consent_changeset(%{consent_analytics: true, consent_analytics_at: now})
    |> Repo.update()
    |> emit_consent(:grant, feature)
  end

  @doc """
  Revokes analytics consent for a user.
  """
  @spec revoke_consent(binary(), String.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def revoke_consent(user_id, feature \\ "analytics") do
    user = Accounts.get_user!(user_id)

    user
    |> Accounts.consent_changeset(%{consent_analytics: false})
    |> Repo.update()
    |> emit_consent(:revoke, feature)
  end

  @doc """
  Returns true if the user has granted consent for the given feature.
  """
  @spec check_consent(binary(), String.t()) :: boolean()
  def check_consent(user_id, _feature \\ "analytics") do
    case Accounts.get_user(user_id) do
      nil -> false
      user -> user.consent_analytics == true
    end
  end

  # GDPR telemetry: fire one event per successful consent transition so the
  # grant/revoke rates are observable. Only successful updates count — a failed
  # changeset is not a consent decision. Registered in
  # `Core.PromEx.Plugins.Stacks` as `stacks_gdpr_consent_{grant,revoke}_count_total`.
  defp emit_consent({:ok, _user} = result, action, feature) do
    :telemetry.execute([:stacks, :gdpr, :consent, action], %{count: 1}, %{feature: feature})
    result
  end

  defp emit_consent(other, _action, _feature), do: other
end
