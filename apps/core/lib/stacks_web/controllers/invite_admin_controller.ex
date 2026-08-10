defmodule StacksWeb.InviteAdminController do
  @moduledoc """
  The owner's invitation surface (US-14.1.3): list, write, revoke.

  Behind `:admin` (MFA-verified session) AND `:require_owner` — the role is
  re-checked where the write happens (#340's lesson: an admin token outlives
  the role it was minted under), and a future non-owner admin must not be able
  to widen the beta.

  `POST` is the ONLY response that ever contains the full `code`; every other
  read carries `code_prefix` only — the code is unrecoverable after issue.
  """

  use CoreWeb, :controller

  import StacksWeb.ChangesetHelpers, only: [format_errors: 1]

  alias Stacks.Accounts.Invites

  @doc "GET /api/admin/invites"
  def index(conn, _params) do
    invites =
      Enum.map(Invites.list(), fn %{invite: invite, redeemed_by_handle: handle} ->
        invite_json(invite, handle)
      end)

    json(conn, %{invites: invites})
  end

  @doc "POST /api/admin/invites"
  def create(conn, params) do
    owner = conn.assigns.current_user

    case Invites.issue(
           owner,
           Map.take(params, ["note", "invited_email", "max_uses", "expires_in_days"])
         ) do
      {:ok, %{invite: invite, code: code}} ->
        conn
        |> put_status(201)
        |> json(%{invite: Map.put(invite_json(invite, nil), :code, code)})

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  @doc "DELETE /api/admin/invites/:id"
  def delete(conn, %{"id" => id}) do
    owner = conn.assigns.current_user

    case Invites.revoke(owner, id) do
      {:ok, invite} ->
        json(conn, %{
          invite: %{id: invite.id, revoked_at: DateTime.to_iso8601(invite.revoked_at)}
        })

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})
    end
  end

  defp invite_json(invite, redeemed_by_handle) do
    %{
      id: invite.id,
      code_prefix: invite.code_prefix,
      note: invite.note,
      invited_email: invite.invited_email,
      max_uses: invite.max_uses,
      use_count: invite.use_count,
      expires_at: invite.expires_at && DateTime.to_iso8601(invite.expires_at),
      revoked_at: invite.revoked_at && DateTime.to_iso8601(invite.revoked_at),
      redeemed_at: invite.redeemed_at && DateTime.to_iso8601(invite.redeemed_at),
      redeemed_by_handle: redeemed_by_handle,
      created_at: DateTime.to_iso8601(invite.created_at)
    }
  end
end
