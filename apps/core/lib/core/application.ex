defmodule Core.Application do
  @moduledoc false

  use Application

  alias Stacks.Telemetry.Reporter, as: TelemetryReporter

  @impl true
  def start(_type, _args) do
    TelemetryReporter.attach()

    children =
      cluster_children() ++
        [
          Core.Repo
        ] ++
        oban_repo_child() ++
        [
          Stacks.Vault,
          {Phoenix.PubSub, name: Core.PubSub},
          finch_spec(),
          Stacks.Accounts.ArgonPool,
          Stacks.CircuitBreakers,
          StacksWeb.Plugs.RateLimiter.Server,
          Stacks.AI.BudgetTracker,
          {Task.Supervisor, name: Stacks.Books.CacheWriteSupervisor},
          Stacks.Books.BookDetailCache,
          Stacks.Books.ISBNResolverCache,
          Stacks.Books.TitleSearchCache,
          Stacks.Transparency.Cache,
          {Oban, Application.fetch_env!(:core, Oban)},
          CoreWeb.Telemetry,
          Core.PromEx,
          Core.PromEx.MetricsPusher
        ] ++ endpoint_children() ++ pipeline_children()

    opts = [strategy: :one_for_one, name: Core.Supervisor]
    result = Supervisor.start_link(children, opts)
    boot_id = Ecto.UUID.generate()
    :persistent_term.put({Stacks.Application, :boot_id}, boot_id)
    result
  end

  @doc "Returns the unique identifier for this application boot."
  def boot_id, do: :persistent_term.get({Stacks.Application, :boot_id})

  defp oban_repo_child do
    oban_repo = Application.fetch_env!(:core, Oban)[:repo]

    if oban_repo == Core.ObanRepo do
      [Core.ObanRepo]
    else
      []
    end
  end

  defp cluster_children do
    topologies = Application.get_env(:libcluster, :topologies, [])

    if topologies == [] do
      []
    else
      [{Cluster.Supervisor, [topologies, [name: Core.ClusterSupervisor]]}]
    end
  end

  @connect_timeout_ms 5_000

  defp finch_spec do
    vision_url = Application.get_env(:core, :vision_service_url, "http://localhost:8000")
    scraper_url = Application.get_env(:core, :scraper_service_url, "http://localhost:8080")
    searxng_url = Application.get_env(:core, :searxng_url, "http://localhost:8888")
    metrics_push_url = Application.get_env(:core, :metrics_push_url)
    metrics_query_url = Application.get_env(:core, :metrics_query_url)
    log_shipper_url = Application.get_env(:core, :log_shipper_keepalive_url)

    inet6_pool = [conn_opts: [transport_opts: [inet6: true, timeout: @connect_timeout_ms]]]

    pools =
      [vision_url, scraper_url, searxng_url, metrics_push_url, metrics_query_url, log_shipper_url]
      |> Enum.filter(&sixpn_url?/1)
      |> Map.new(&{pool_key(&1), inet6_pool})
      |> Map.put(:default, conn_opts: [transport_opts: [timeout: @connect_timeout_ms]])

    {Finch, name: Stacks.Finch, pools: pools}
  end

  defp sixpn_url?(url) when is_binary(url),
    do: String.contains?(url, ".internal") or String.contains?(url, ".flycast")

  defp sixpn_url?(_), do: false

  defp pool_key(url) do
    uri = URI.parse(url)
    port = uri.port || URI.default_port(uri.scheme)
    "#{uri.scheme}://#{uri.host}:#{port}"
  end

  defp endpoint_children do
    if System.get_env("STACKS_SKIP_ENDPOINT") in [nil, ""] do
      [CoreWeb.Endpoint]
    else
      []
    end
  end

  defp pipeline_children do
    if Application.get_env(:core, :env) == :test do
      []
    else
      [{Stacks.Enrichment.PricePipeline, []}]
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    CoreWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
