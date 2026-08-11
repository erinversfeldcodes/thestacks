defmodule StacksWeb.Plugs.RouteGroup do
  @moduledoc """
  Classifies the request path into a feature group (`:auth`,
  `:catalogue`, `:bookshelves`, `:upload`, `:gdpr`, `:settings`,
  `:health`, `:metrics`, `:other`) for per-group SLO thresholds (136).
  Writes the tag to `conn.private[:route_group]`,
  `private[:telemetry_metadata][:route_group]` and
  `assigns[:route_group]`;
  `CoreWeb.Telemetry.attach_route_group_handler/0` copies it into
  `[:phoenix, :router_dispatch, :stop]` metadata at emit time.
  """

  @behaviour Plug

  @rules [
    {"/api/auth/", :auth},
    {"/api/catalogue", :catalogue},
    {"/api/books/", :catalogue},
    {"/api/books", :catalogue},
    {"/api/bookshelves/", :bookshelves},
    {"/api/placements/", :bookshelves},
    {"/api/upload/", :upload},
    {"/api/upload", :upload},
    {"/api/gdpr/", :gdpr},
    {"/api/settings/", :settings},
    {"/api/health", :health},
    {"/internal/metrics", :metrics}
  ]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: path} = conn, _opts) do
    group = classify(path)
    stash(conn, group)
  end

  @doc "Classify a request path into a route group. Public for testing."
  @spec classify(String.t()) :: atom()
  def classify(path) when is_binary(path) do
    Enum.find_value(@rules, :other, fn {prefix, group} ->
      if prefix_matches?(path, prefix), do: group, else: nil
    end)
  end

  defp prefix_matches?(path, prefix) do
    if String.ends_with?(prefix, "/") do
      String.starts_with?(path, prefix)
    else
      path == prefix or String.starts_with?(path, prefix <> "/")
    end
  end

  defp stash(conn, group) do
    telemetry_meta =
      conn.private
      |> Map.get(:telemetry_metadata, %{})
      |> Map.put(:route_group, group)

    conn
    |> Plug.Conn.put_private(:route_group, group)
    |> Plug.Conn.put_private(:telemetry_metadata, telemetry_meta)
    |> Plug.Conn.assign(:route_group, group)
  end
end
