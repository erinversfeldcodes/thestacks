defmodule StacksWeb.ThirdSpaceController do
  use CoreWeb, :controller

  alias Stacks.Enrichment

  def index(conn, params) do
    opts = parse_geo_opts(params)
    spaces = Enrichment.list_third_spaces(opts)
    render(conn, :index, third_spaces: spaces)
  end

  defp parse_geo_opts(params) do
    with {:ok, lat} <- parse_float(params["lat"]),
         {:ok, lng} <- parse_float(params["lng"]),
         {:ok, radius_km} <- parse_float(params["radius_km"]) do
      [lat: lat, lng: lng, radius_km: radius_km]
    else
      _ -> []
    end
  end

  defp parse_float(nil), do: :error

  defp parse_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> {:ok, f}
      :error -> :error
    end
  end
end
