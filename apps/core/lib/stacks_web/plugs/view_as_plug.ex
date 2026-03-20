defmodule StacksWeb.Plugs.ViewAsPlug do
  @moduledoc """
  Allows the platform owner to preview content as different viewer types.

  Reads the `?view_as=<perspective>` query parameter and, if present, validates
  that the current user is the platform owner (role: "owner"), then assigns
  `conn.assigns[:view_as_context]` for use by downstream controllers.

  Supported perspective values:
  - `"unauthenticated"` — simulate an anonymous visitor
  - `"platform"` — simulate a generic authenticated platform user (current owner's id)
  - `"user:<uuid>"` — simulate a specific user by id
  - `"group:<uuid>"` — simulate a group member by group id

  Non-owner users receive 403. Invalid perspective values receive 422.
  If no `?view_as` param is present the conn passes through unchanged.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Stacks.Accounts.Guardian

  @behaviour Plug

  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case Map.get(conn.query_params, "view_as") do
      nil -> conn
      perspective -> handle_view_as(conn, perspective)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec handle_view_as(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp handle_view_as(conn, perspective) do
    user = Guardian.Plug.current_resource(conn)

    if owner?(user) do
      apply_perspective(conn, perspective, user)
    else
      conn
      |> put_status(403)
      |> json(%{error: "forbidden"})
      |> halt()
    end
  end

  @spec owner?(map() | nil) :: boolean()
  defp owner?(%{role: "owner"}), do: true
  defp owner?(_), do: false

  @spec apply_perspective(Plug.Conn.t(), String.t(), map()) :: Plug.Conn.t()
  defp apply_perspective(conn, "unauthenticated", _user) do
    assign(conn, :view_as_context, :unauthenticated)
  end

  defp apply_perspective(conn, "platform", user) do
    assign(conn, :view_as_context, {:platform_user, user.id})
  end

  defp apply_perspective(conn, "user:" <> id, _user) when byte_size(id) > 0 do
    assign(conn, :view_as_context, {:specific_user, id})
  end

  defp apply_perspective(conn, "user:", _user) do
    conn
    |> put_status(422)
    |> json(%{error: "invalid_perspective", detail: "user id is required"})
    |> halt()
  end

  defp apply_perspective(conn, "group:" <> id, _user) when byte_size(id) > 0 do
    assign(conn, :view_as_context, {:group, id})
  end

  defp apply_perspective(conn, "group:", _user) do
    conn
    |> put_status(422)
    |> json(%{error: "invalid_perspective", detail: "group id is required"})
    |> halt()
  end

  defp apply_perspective(conn, _unknown, _user) do
    conn
    |> put_status(422)
    |> json(%{error: "invalid_perspective"})
    |> halt()
  end
end
