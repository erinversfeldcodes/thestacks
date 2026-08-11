defmodule StacksWeb.UserSearchController do
  @moduledoc """
    People search for the discovery surface.

    `GET /api/search/users?q=<term>` runs under `:optional_auth`. Results are the
    redacted `public_profile_summary` shape (handle + display_name + location) —
    never email, consent, or role.

    The discoverability privacy rule (platform-only, block-excluded in both
    directions) is enforced **in SQL** by `Accounts.search_users/2`, never by
    redacting here — a ghost or blocked user never enters the result set.
  """
  use CoreWeb, :controller

  alias Stacks.Accounts
  alias Stacks.Accounts.Guardian
  alias StacksWeb.ProtoJSON

  @doc "GET /api/search/users?q=<term> — discoverable, non-blocked readers by name."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    term = Map.get(params, "q", "")
    viewer_id = viewer_id(conn)

    matches = Accounts.search_users(term, viewer_id)

    outcome = if matches == [], do: :zero_result, else: :hit

    :telemetry.execute(
      [:stacks, :search, :people],
      %{count: 1, results: length(matches)},
      %{outcome: outcome}
    )

    results = Enum.map(matches, &ProtoJSON.public_profile_summary/1)

    json(conn, %{users: results})
  end

  defp viewer_id(conn) do
    case Guardian.Plug.current_resource(conn) do
      nil -> nil
      %{id: id} -> id
    end
  end
end
