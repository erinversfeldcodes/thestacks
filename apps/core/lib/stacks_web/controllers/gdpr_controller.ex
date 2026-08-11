defmodule StacksWeb.GDPRController do
  @moduledoc "Handles GDPR data export, account deletion, and consent management."

  use CoreWeb, :controller

  import StacksWeb.ChangesetHelpers, only: [format_errors: 1]

  alias Stacks.Accounts.Guardian
  alias Stacks.Audit
  alias Stacks.GDPR.Consent
  alias Stacks.Workers.AccountDeletionJob
  alias Stacks.Workers.DataExportJob

  @doc "POST /api/gdpr/export — enqueue a data export job."
  def export(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    {:ok, _job} =
      %{"user_id" => user.id}
      |> DataExportJob.new()
      |> Oban.insert()

    conn
    |> put_status(202)
    |> json(%{status: "accepted", message: "Data export has been queued."})
  end

  @doc "DELETE /api/gdpr/account — enqueue an account deletion job."
  def delete_account(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    Audit.log(user.id, "user.deletion_requested",
      resource_type: "user",
      resource_id: user.id
    )

    {:ok, _job} =
      %{"user_id" => user.id}
      |> AccountDeletionJob.new()
      |> Oban.insert()

    conn
    |> put_status(202)
    |> json(%{status: "accepted", message: "Account deletion has been queued."})
  end

  @consent_types %{"analytics" => "analytics", "writing_assistant" => "writing_assistant"}

  @doc """
    POST /api/gdpr/consent — grant or revoke consent for a feature.

    Body: `consent` (bool, required) + optional `type` ("analytics" default |
    "writing_assistant"). An unknown `type` → 422 (whitelisted, never passed
    through raw). Returns the matching consent flag + timestamp.
  """
  def update_consent(conn, %{"consent" => consent} = params) do
    user = Guardian.Plug.current_resource(conn)

    with {:ok, feature} <- whitelist_type(Map.get(params, "type", "analytics")),
         {:ok, updated_user} <- apply_consent(user.id, consent, feature) do
      json(conn, consent_payload(updated_user, feature))
    else
      {:error, :invalid_consent_type} ->
        conn
        |> put_status(422)
        |> json(%{error: "type must be one of: analytics, writing_assistant"})

      {:error, :invalid_consent_value} ->
        conn
        |> put_status(422)
        |> json(%{error: "consent must be true or false"})

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def update_consent(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "consent parameter is required"})
  end

  defp whitelist_type(type) do
    case Map.fetch(@consent_types, type) do
      {:ok, feature} -> {:ok, feature}
      :error -> {:error, :invalid_consent_type}
    end
  end

  defp apply_consent(user_id, true, feature), do: Consent.grant_consent(user_id, feature)
  defp apply_consent(user_id, false, feature), do: Consent.revoke_consent(user_id, feature)
  defp apply_consent(_user_id, _consent, _feature), do: {:error, :invalid_consent_value}

  defp consent_payload(user, "writing_assistant") do
    %{
      consent_writing_assistant: user.consent_writing_assistant,
      consent_writing_assistant_at: user.consent_writing_assistant_at
    }
  end

  defp consent_payload(user, _analytics) do
    %{
      consent_analytics: user.consent_analytics,
      consent_analytics_at: user.consent_analytics_at
    }
  end
end
