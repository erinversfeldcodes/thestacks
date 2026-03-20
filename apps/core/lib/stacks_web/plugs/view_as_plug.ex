defmodule StacksWeb.Plugs.ViewAsPlug do
  @moduledoc """
  Allows users to preview content as different viewer types.

  Reads the `?view_as=<perspective>` query parameter and, if present, validates
  that the current user is permitted, then assigns `conn.assigns[:view_as_context]`
  for use by downstream controllers.

  ## Who may use ViewAs

  - **Platform owner** (`role: "owner"`): may use any perspective on any resource.
  - **Regular users**: may use `"unauthenticated"` and `"platform"` perspectives,
    but only on resources they own. The controller must set
    `conn.assigns[:resource_owner_id]` to the resource owner's user ID before
    calling this plug.

  ## Supported perspective values

  - `"unauthenticated"` — simulate an anonymous visitor
  - `"platform"` — simulate a generic authenticated platform user
  - `"user:<uuid>"` — simulate a specific user by id (owner-only)
  - `"group:<uuid>"` — not yet implemented; returns 422

  Non-permitted users receive 403. Invalid perspective values receive 422.
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

    cond do
      platform_owner?(user) ->
        apply_perspective(conn, perspective, user)

      resource_owner?(user, conn) ->
        apply_perspective_for_resource_owner(conn, perspective, user)

      true ->
        conn
        |> put_status(403)
        |> json(%{error: "forbidden"})
        |> halt()
    end
  end

  @spec platform_owner?(map() | nil) :: boolean()
  defp platform_owner?(%{role: "owner"}), do: true
  defp platform_owner?(_), do: false

  @spec resource_owner?(map() | nil, Plug.Conn.t()) :: boolean()
  defp resource_owner?(%{id: user_id}, %{assigns: %{resource_owner_id: owner_id}}) do
    user_id == owner_id
  end

  defp resource_owner?(_, _), do: false

  # Platform owners may use any perspective.
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
    conn
    |> put_status(422)
    |> json(%{error: "not_implemented", detail: "group perspective is not yet supported"})
    |> halt()
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

  # Regular resource owners may only preview as unauthenticated or platform —
  # not as arbitrary specific users.
  @spec apply_perspective_for_resource_owner(Plug.Conn.t(), String.t(), map()) :: Plug.Conn.t()
  defp apply_perspective_for_resource_owner(conn, "unauthenticated", _user) do
    assign(conn, :view_as_context, :unauthenticated)
  end

  defp apply_perspective_for_resource_owner(conn, "platform", user) do
    assign(conn, :view_as_context, {:platform_user, user.id})
  end

  defp apply_perspective_for_resource_owner(conn, _perspective, _user) do
    conn
    |> put_status(403)
    |> json(%{error: "forbidden", detail: "only platform owners may use this perspective"})
    |> halt()
  end
end
