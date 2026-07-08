defmodule StacksWeb.Plugs.RouteGroup do
  @moduledoc """
  Classifies the incoming request path into a feature group (`:auth`,
  `:catalogue`, `:bookshelves`, `:upload`, `:gdpr`, `:settings`, `:health`,
  `:metrics`, or `:other`) and stashes that tag on the conn so it can flow
  through into telemetry metadata.

  The tag feeds the SLO gate in Issue #136 — thresholds are computed per
  route group against `phoenix.router_dispatch.stop.duration`.

  The plug writes the tag to three places so downstream consumers can read
  it in whichever form is most convenient:

    * `conn.private[:route_group]`
    * `conn.private[:telemetry_metadata][:route_group]`
    * `conn.assigns[:route_group]`

  `CoreWeb.Telemetry.attach_route_group_handler/0` attaches a telemetry
  handler that copies `conn.private[:route_group]` into the
  `[:phoenix, :router_dispatch, :stop]` metadata so the per-group Phoenix
  metrics see the tag at emit time.
  """

  @behaviour Plug

  # Longest-prefix-first. Static prefixes are compared with String.starts_with?/2.
  # Order matters: `/api/bookshelves/` must win over a hypothetical `/api/b` entry.
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

  # Exact match for paths without a trailing slash, prefix match for those with.
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
