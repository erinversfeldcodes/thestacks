defmodule StacksWeb.Plugs.ViewAsPlug do
  @moduledoc """
  Two-phase ViewAs support for content preview.

  ## Phase 1: Router pipeline plug (`call/2`)

  Parses `?view_as=<perspective>` and stores the parsed perspective in
  `conn.assigns[:requested_perspective]`. Halts with 422 on invalid or
  unimplemented perspective formats. Does NOT check ownership.

  ## Phase 2: Controller helper (`authorize_view_as/2`)

  Called by controllers after loading the resource:

      conn = ViewAsPlug.authorize_view_as(conn, resource_owner_id)

  Checks whether the current user may use the requested perspective on
  that resource, then sets `conn.assigns[:view_as_context]` or halts 403.

  ## Permissions

  - **Platform owner** (`role: "owner"`): any perspective on any resource.
  - **Resource owner** (`user.id == resource_owner_id`): `"unauthenticated"`
    and `"platform"` on their own resources.
  - **Others**: 403.

  ## Supported perspectives

  - `"unauthenticated"` — simulate an anonymous visitor
  - `"platform"` — simulate a generic authenticated platform user
  - `"user:<uuid>"` — simulate a specific user (platform owner only)
  - `"group:<uuid>"` — not yet implemented; halts 422
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
      perspective -> parse_perspective(conn, perspective)
    end
  end

  @doc """
  Authorizes the requested perspective for a resource owned by
  `resource_owner_id`. Call this from controller actions after loading
  the resource.

  - Returns `conn` unchanged if no `?view_as` was requested.
  - Sets `conn.assigns[:view_as_context]` on success.
  - Halts with 403 if the user lacks permission.
  """
  @spec authorize_view_as(Plug.Conn.t(), binary()) :: Plug.Conn.t()
  def authorize_view_as(conn, resource_owner_id) do
    case conn.assigns[:requested_perspective] do
      nil -> conn
      perspective -> check_ownership(conn, perspective, resource_owner_id)
    end
  end

  defp parse_perspective(conn, "unauthenticated") do
    emit_usage(:unauthenticated)
    assign(conn, :requested_perspective, :unauthenticated)
  end

  defp parse_perspective(conn, "platform") do
    emit_usage(:platform)
    assign(conn, :requested_perspective, :platform)
  end

  defp parse_perspective(conn, "user:" <> id) when byte_size(id) > 0 do
    emit_usage(:specific_user)
    assign(conn, :requested_perspective, {:specific_user, id})
  end

  defp parse_perspective(conn, "user:") do
    emit_error(:invalid_perspective, :parse)

    conn
    |> put_status(422)
    |> json(%{error: "invalid_perspective", detail: "user id is required"})
    |> halt()
  end

  defp parse_perspective(conn, "group:" <> id) when byte_size(id) > 0 do
    emit_error(:not_implemented, :parse)

    conn
    |> put_status(422)
    |> json(%{error: "not_implemented", detail: "group perspective is not yet supported"})
    |> halt()
  end

  defp parse_perspective(conn, "group:") do
    emit_error(:invalid_perspective, :parse)

    conn
    |> put_status(422)
    |> json(%{error: "invalid_perspective", detail: "group id is required"})
    |> halt()
  end

  defp parse_perspective(conn, _unknown) do
    emit_error(:invalid_perspective, :parse)

    conn
    |> put_status(422)
    |> json(%{error: "invalid_perspective"})
    |> halt()
  end

  defp emit_usage(perspective) do
    :telemetry.execute([:stacks, :view_as, :usage], %{count: 1}, %{perspective: perspective})
  end

  defp emit_error(reason, phase) do
    :telemetry.execute([:stacks, :view_as, :error], %{count: 1}, %{reason: reason, phase: phase})
  end

  defp check_ownership(conn, perspective, resource_owner_id) do
    user = Guardian.Plug.current_resource(conn)

    cond do
      platform_owner?(user) ->
        apply_perspective(conn, perspective, user)

      owns_resource?(user, resource_owner_id) ->
        apply_limited_perspective(conn, perspective, user)

      true ->
        emit_error(:forbidden, :authorize)

        conn
        |> put_status(403)
        |> json(%{error: "forbidden"})
        |> halt()
    end
  end

  defp platform_owner?(%{role: "owner"}), do: true
  defp platform_owner?(_), do: false

  defp owns_resource?(%{id: user_id}, resource_owner_id), do: user_id == resource_owner_id
  defp owns_resource?(_, _), do: false

  defp apply_perspective(conn, :unauthenticated, _user) do
    assign(conn, :view_as_context, :unauthenticated)
  end

  defp apply_perspective(conn, :platform, _user) do
    assign(conn, :view_as_context, :platform_preview)
  end

  defp apply_perspective(conn, {:specific_user, id}, _user) do
    assign(conn, :view_as_context, {:platform_user, id})
  end

  defp apply_limited_perspective(conn, :unauthenticated, _user) do
    assign(conn, :view_as_context, :unauthenticated)
  end

  defp apply_limited_perspective(conn, :platform, _user) do
    assign(conn, :view_as_context, :platform_preview)
  end

  defp apply_limited_perspective(conn, _perspective, _user) do
    emit_error(:forbidden, :authorize)

    conn
    |> put_status(403)
    |> json(%{error: "forbidden", detail: "only platform owners may use this perspective"})
    |> halt()
  end
end
