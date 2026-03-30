defmodule StacksWeb.GroupFeedController do
  @moduledoc "GET /api/groups/:id/feed"

  use CoreWeb, :controller

  alias Stacks.Social
  alias StacksWeb.ProtoJSON

  action_fallback CoreWeb.FallbackController

  def index(conn, %{"id" => group_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    opts = build_opts(params)

    case Social.feed_for_group(group_id, user.id, opts) do
      {:ok, items} ->
        json(conn, %{
          data: Enum.map(items, &ProtoJSON.feed_item/1),
          next_cursor: next_cursor(items)
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_opts(params) do
    limit = parse_limit(Map.get(params, "limit", "20"))

    case Map.get(params, "before") do
      nil -> [limit: limit]
      before_str -> parse_before(before_str, limit)
    end
  end

  defp parse_limit(str) do
    case Integer.parse(str) do
      {n, _} -> min(n, 50)
      :error -> 20
    end
  end

  defp parse_before(str, limit) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> [limit: limit, before: dt]
      _ -> [limit: limit]
    end
  end

  defp next_cursor([]), do: nil
  defp next_cursor(items), do: DateTime.to_iso8601(List.last(items).occurred_at)
end
