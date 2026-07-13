defmodule Stacks.GDPR.Consent do
  @moduledoc """
  GDPR consent management. Handles granting, revoking, and checking user consent
  for a bounded set of features. Consent timestamps are always recorded.

  Two features are supported today:

    * `"analytics"`          — anonymised usage analytics (default feature).
    * `"writing_assistant"`  — the AI writing assistant (Issue #184). Revoking it
      enqueues `WritingAssistantDataPurgeWorker`, which erases the user's AI
      session history + embeddings (the personal data collected under the grant).

  The `feature` string is treated as a bounded label: callers MUST pass one of
  the known values. `emit_consent/3` fires it as a `:telemetry` metadata tag, so
  an unbounded user-supplied string would blow up Prometheus label cardinality —
  the HTTP boundary (`StacksWeb.GDPRController`) whitelists it before we get here.
  """

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Accounts.User
  alias Stacks.Workers.WritingAssistantDataPurgeWorker

  @doc """
  Grants consent for a user for the given feature. Records the timestamp.
  """
  @spec grant_consent(binary(), String.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def grant_consent(user_id, feature \\ "analytics") do
    user = Accounts.get_user!(user_id)
    now = DateTime.utc_now()

    user
    |> Accounts.consent_changeset(grant_attrs(feature, now))
    |> Repo.update()
    |> emit_consent(:grant, feature)
  end

  @doc """
  Revokes consent for a user for the given feature.

  Revoking `"writing_assistant"` additionally enqueues a
  `WritingAssistantDataPurgeWorker` for the user: withdrawing consent must delete
  the AI data that was collected under it (session history + embeddings). The
  purge is enqueued only after the consent flag is successfully cleared.
  """
  @spec revoke_consent(binary(), String.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def revoke_consent(user_id, feature \\ "analytics") do
    result =
      user_id
      |> Accounts.get_user!()
      |> Accounts.consent_changeset(revoke_attrs(feature))
      |> Repo.update()
      |> emit_consent(:revoke, feature)

    maybe_purge_on_revoke(result, feature)
  end

  @doc """
  Returns true if the user has granted consent for the given feature.
  """
  @spec check_consent(binary(), String.t()) :: boolean()
  def check_consent(user_id, feature \\ "analytics") do
    case Accounts.get_user(user_id) do
      nil -> false
      user -> consented?(user, feature)
    end
  end

  # ---------------------------------------------------------------------------
  # Feature → column mapping. Only known features reach here (whitelisted at the
  # HTTP boundary); an unknown feature falls back to the analytics columns rather
  # than raising, but is never reachable via the controller.
  # ---------------------------------------------------------------------------

  defp grant_attrs("writing_assistant", now),
    do: %{consent_writing_assistant: true, consent_writing_assistant_at: now}

  defp grant_attrs(_analytics, now),
    do: %{consent_analytics: true, consent_analytics_at: now}

  defp revoke_attrs("writing_assistant"), do: %{consent_writing_assistant: false}
  defp revoke_attrs(_analytics), do: %{consent_analytics: false}

  defp consented?(%User{consent_writing_assistant: v}, "writing_assistant"), do: v == true
  defp consented?(%User{consent_analytics: v}, _analytics), do: v == true

  # On a successful writing_assistant revoke, enqueue the data purge. A failed
  # consent update does not enqueue (nothing changed). Analytics revoke never
  # purges.
  defp maybe_purge_on_revoke({:ok, user} = result, "writing_assistant") do
    %{"user_id" => user.id}
    |> WritingAssistantDataPurgeWorker.new()
    |> Oban.insert()

    result
  end

  defp maybe_purge_on_revoke(result, _feature), do: result

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
