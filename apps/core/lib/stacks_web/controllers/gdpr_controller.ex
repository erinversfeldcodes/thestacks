defmodule StacksWeb.GDPRController do
  @moduledoc "Handles GDPR data export, account deletion, and consent management."

  use CoreWeb, :controller

  alias Stacks.Accounts.Guardian
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

    {:ok, _job} =
      %{"user_id" => user.id}
      |> AccountDeletionJob.new()
      |> Oban.insert()

    conn
    |> put_status(202)
    |> json(%{status: "accepted", message: "Account deletion has been queued."})
  end

  @doc "POST /api/gdpr/consent — grant analytics consent."
  def update_consent(conn, %{"consent" => consent}) do
    user = Guardian.Plug.current_resource(conn)

    result =
      case consent do
        true -> Consent.grant_consent(user.id)
        false -> Consent.revoke_consent(user.id)
        _ -> {:error, :invalid_consent_value}
      end

    case result do
      {:ok, updated_user} ->
        json(conn, %{
          consent_analytics: updated_user.consent_analytics,
          consent_analytics_at: updated_user.consent_analytics_at
        })

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

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
