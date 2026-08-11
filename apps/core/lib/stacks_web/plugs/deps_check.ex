defmodule StacksWeb.Plugs.DepsCheck do
  @moduledoc """
    Synthetic dependency probe for the SLO gate: `GET /internal/deps-check`
    (handled at the endpoint, before the router) synchronously exercises
    in-cluster deps with no other synthetic coverage — today SearXNG, whose
    fuse sits in its healthy initial state on a fresh deploy whether or not
    SearXNG works (the cold-start blind spot this closes). Assumes
    `MetricsAuth` has already passed upstream. JSON body always; the status
    code carries the aggregate (200 all-ok / 503 any-failed).
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
