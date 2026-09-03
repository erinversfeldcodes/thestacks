defmodule StacksWeb.AdminController do
  @moduledoc """
      Admin data access controller.

      Provides break-glass admin endpoints for querying user data, audit logs,
      platform statistics, and performing GDPR operations. All endpoints require
      a valid admin token with MFA verification and are audited via the
      `AuditAdminCall` plug.
  """

  use CoreWeb, :controller

  alias Stacks.Accounts
  alias Stacks.Admin.Data
  alias Stacks.Audit
  alias Stacks.GDPR.Deletion
  alias Stacks.GDPR.Export

  @doc "GET /api/admin/users/by_email"
  @spec by_email(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def by_email(conn, %{"email" => email}) do
    case Data.get_user_by_email(email) do
      {:ok, user_map} ->
        conn
        |> assign(:audit_row_count, 1)
        |> json(%{user: user_map})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "user_not_found"})
    end
  end

  @doc "GET /api/admin/users/by_id"
  @spec by_id(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def by_id(conn, %{"id" => id}) do
    case Data.get_user_by_id(id) do
      {:ok, user_map} ->
        conn
        |> assign(:audit_row_count, 1)
        |> json(%{user: user_map})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "user_not_found"})
    end
  end

  @doc "GET /api/admin/audit_log"
  @spec audit_log(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def audit_log(conn, params) do
    user_id = params["user_id"]

    with {:ok, from_dt} <- parse_datetime(params["from"], :from),
         {:ok, to_dt} <- parse_datetime(params["to"], :to),
         {:ok, entries} <- Data.list_audit_log(user_id, from_dt, to_dt) do
      conn
      |> assign(:audit_row_count, length(entries))
      |> json(%{entries: entries})
    else
      {:error, :invalid_datetime} ->
        conn
        |> put_status(422)
        |> json(%{error: "invalid_params"})

      {:error, :invalid_params} ->
        conn
        |> put_status(422)
        |> json(%{error: "invalid_params"})
    end
  end

  @doc "GET /api/admin/platform_stats"
  @spec platform_stats(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def platform_stats(conn, _params) do
    {:ok, stats} = Data.platform_stats()
    json(conn, %{stats: stats})
  end

  @doc "GET /api/admin/gdpr_export"
  @spec gdpr_export(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def gdpr_export(conn, %{"user_id" => user_id}) do
    case Export.export_user_data(user_id) do
      {:ok, export_map} ->
        conn
        |> assign(:audit_row_count, 1)
        |> json(%{export: export_map})

      {:error, _reason} ->
        conn
        |> put_status(404)
        |> json(%{error: "user_not_found"})
    end
  end

  @doc "GET /api/admin/degraded_accounts"
  @spec degraded_accounts(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def degraded_accounts(conn, _params) do
    accounts = Accounts.list_degraded_accounts()

    conn
    |> assign(:audit_row_count, length(accounts))
    |> json(%{
      accounts:
        Enum.map(accounts, fn u ->
          %{
            user_id: u.id,
            email: u.email,
            pending_email: u.pending_email,
            pending_email_sent_at: u.pending_email_sent_at
          }
        end)
    })
  end

  @doc "POST /api/admin/degraded_accounts/restore"
  @spec restore_degraded_account(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def restore_degraded_account(conn, %{"user_id" => user_id}) do
    case Accounts.restore_degraded_account(user_id) do
      {:ok, restored} ->
        # Named here rather than left to the admin-call plug: that plug records
        # that an endpoint was hit, while this records WHICH account an operator
        # reached into and put back. Un-degrading an account without a trace
        # would be worse than the lockout it fixes.
        Audit.log(
          conn.assigns[:current_user] && conn.assigns.current_user.id,
          "admin.account_restored",
          resource_type: "user",
          resource_id: restored.id,
          operator_session_id: conn.assigns[:admin_session] && conn.assigns.admin_session.id
        )

        conn
        |> assign(:audit_row_count, 1)
        |> json(%{ok: true, email: restored.email})

      {:error, :user_not_found} ->
        conn |> put_status(404) |> json(%{error: "user_not_found"})

      {:error, :not_degraded} ->
        conn |> put_status(422) |> json(%{error: "not_degraded"})

      {:error, _reason} ->
        conn |> put_status(422) |> json(%{error: "restore_failed"})
    end
  end

  def restore_degraded_account(conn, _params) do
    conn |> put_status(422) |> json(%{error: "user_id_required"})
  end

  @doc "POST /api/admin/gdpr_erase"
  @spec gdpr_erase(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def gdpr_erase(conn, params) do
    user_id = params["user_id"]
    reason = params["reason"]

    cond do
      is_nil(reason) or String.trim(reason) == "" ->
        conn
        |> put_status(422)
        |> json(%{error: "reason_required"})

      # The reason is stored in the `user.data_deleted` audit row, which is kept
      # after the erasure on purpose. Personal data pasted in here would outlive
      # the deletion it authorised, so it is refused rather than quietly stored.
      Stacks.Audit.reason_carries_personal_data?(reason) ->
        conn
        |> put_status(422)
        |> json(%{
          error: "reason_carries_personal_data",
          detail:
            "The reason is kept in an audit row that outlives this erasure. " <>
              "Reference a ticket instead of naming the person."
        })

      true ->
        case Deletion.delete_user_data(user_id, reason: reason, actor: "admin_api") do
          {:ok, _} ->
            conn
            |> assign(:audit_row_count, 1)
            |> json(%{ok: true})

          {:error, _, _, _} ->
            conn
            |> put_status(422)
            |> json(%{error: "erase_failed"})
        end
    end
  end

  defp parse_datetime(nil, :from) do
    {:ok, DateTime.add(DateTime.utc_now(), -30, :day)}
  end

  defp parse_datetime(nil, :to) do
    {:ok, DateTime.utc_now()}
  end

  defp parse_datetime(str, _direction) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, :invalid_datetime}
    end
  end
end
