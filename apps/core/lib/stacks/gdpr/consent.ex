defmodule Stacks.GDPR.Consent do
  @moduledoc """
      GDPR consent: grant, revoke, check — always with timestamps. Features:
      `"analytics"`, `"writing_assistant"` (revoking the latter enqueues
      `WritingAssistantDataPurgeWorker` to erase AI session history +
      embeddings), and `"search_indexing"` (the per-user opt-in that lets search
      engines index the reader's PUBLIC content; default off, so public content
      stays `noindex` until granted). `feature` must be one of the known labels — it becomes a
      telemetry tag, and an unbounded string would blow up Prometheus label
      cardinality; `GDPRController` whitelists before it reaches here.
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
    now = DateTime.utc_now()

    result =
      user_id
      |> Accounts.get_user!()
      |> Accounts.consent_changeset(revoke_attrs(feature, now))
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

  defp grant_attrs("writing_assistant", now),
    do: %{consent_writing_assistant: true, consent_writing_assistant_at: now}

  defp grant_attrs("search_indexing", now),
    do: %{consent_search_indexing: true, consent_search_indexing_at: now}

  defp grant_attrs(_analytics, now),
    do: %{consent_analytics: true, consent_analytics_at: now}

  # A revoke STAMPS the `_at` column with the withdrawal time — it does not
  # clear it and does not leave the grant time in place. Clearing would destroy
  # the evidence that a withdrawal happened at all, and `false` with a NULL
  # timestamp is indistinguishable from "never answered"; leaving the grant time
  # makes the flag ("no") disagree with the clock ("consented at 14:32"). So the
  # `_at` column means "when this consent value was last set", for grant and
  # revoke alike. (If an audit ever needs the grant time specifically, that is a
  # second column, not a different write to this one.)
  defp revoke_attrs("writing_assistant", now),
    do: %{consent_writing_assistant: false, consent_writing_assistant_at: now}

  defp revoke_attrs("search_indexing", now),
    do: %{consent_search_indexing: false, consent_search_indexing_at: now}

  defp revoke_attrs(_analytics, now),
    do: %{consent_analytics: false, consent_analytics_at: now}

  defp consented?(%User{consent_writing_assistant: v}, "writing_assistant"), do: v == true
  defp consented?(%User{consent_search_indexing: v}, "search_indexing"), do: v == true
  defp consented?(%User{consent_analytics: v}, _analytics), do: v == true

  defp maybe_purge_on_revoke({:ok, user} = result, "writing_assistant") do
    %{"user_id" => user.id}
    |> WritingAssistantDataPurgeWorker.new()
    |> Oban.insert()

    result
  end

  defp maybe_purge_on_revoke(result, _feature), do: result

  defp emit_consent({:ok, _user} = result, action, feature) do
    :telemetry.execute([:stacks, :gdpr, :consent, action], %{count: 1}, %{feature: feature})
    result
  end

  defp emit_consent(other, _action, _feature), do: other
end
