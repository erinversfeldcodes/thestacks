defmodule StacksWeb.Plugs.DepsCheck do
  @moduledoc """
  Synthetic dependency probe for the SLO gate.

  Handles `GET /internal/deps-check` at the endpoint level (before the
  router) and synchronously exercises the in-cluster dependencies that
  otherwise have no synthetic coverage:

    * SearXNG — only invoked as a fallback from
      `Stacks.Workers.SourceDiscoveryJob`. A fresh deploy with no real
      traffic exercising that fallback path leaves the `searxng_fuse`
      circuit breaker in its initial healthy state regardless of whether
      SearXNG actually works, so the existing `searxng_fuse_open` SLI has
      a cold-start blind spot. This probe closes it.

  Bearer-auth is provided upstream by `StacksWeb.Plugs.MetricsAuth`, which
  guards every `/internal/*` path with the shared `METRICS_SCRAPE_TOKEN`.
  This plug assumes auth has already passed.

  ## Response shape

  JSON body always, status code carries the aggregate result:

      200 {"searxng": "ok"}
      503 {"searxng": "error:url_not_configured"}

  Individual dep keys mirror the client module names so operators can add
  new deps (Brave, Open Library, vision, scraper) by appending to
  `@deps` without touching the response contract.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @path "/internal/deps-check"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: @path, method: "GET"} = conn, _opts) do
    results = check_deps()
    all_ok? = Enum.all?(results, fn {_dep, status} -> status == "ok" end)
    status_code = if all_ok?, do: 200, else: 503

    body = Jason.encode!(Map.new(results))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status_code, body)
    |> halt()
  end

  def call(conn, _opts), do: conn

  defp check_deps do
    [
      {"searxng", check_searxng()}
    ]
  end

  defp check_searxng do
    case searxng_client().search("probe", limit: 1) do
      {:ok, _results} ->
        "ok"

      {:error, reason} ->
        Logger.warning("deps-check: searxng failed: #{inspect(reason)}")
        "error:#{inspect(reason)}"
    end
  rescue
    e ->
      Logger.warning("deps-check: searxng raised: #{Exception.message(e)}")
      "error:exception"
  end

  defp searxng_client do
    Application.get_env(
      :core,
      :searxng_client,
      Stacks.Discovery.SearxngClient
    )
  end
end
