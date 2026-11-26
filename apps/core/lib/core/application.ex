defmodule Core.Application do
  @moduledoc false

  use Application

  require Logger

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
    announce_storage_backend()
    result
  end

  # ⛔ SAY WHICH OBJECT STORE THIS NODE IS USING, OUT LOUD, ON EVERY BOOT.
  #
  # The selector is a deliberate statement rather than an inference from a
  # credential, and `Stacks.Storage.Selection` refuses to boot rather than guess.
  # But a correct silent choice is still a silent one, and silence is what let the
  # wrong choice run in production for seven months: every environment was
  # configured for `Local`, writing uploads to a container filesystem that does
  # not survive a restart, and nothing anywhere said so. Reading the config is how
  # you find that out, and nobody reads the config of a system that appears to
  # work.
  #
  # ⚠️ Here rather than in `config/runtime.exs`, where the decision is actually
  # made, because at that point Logger is not started and the line would go
  # nowhere. This runs after the supervision tree is up, so it lands in the
  # aggregated logs that an operator actually greps.
  #
  # ⚖️ The bucket name and upload directory are configuration, not secrets, and
  # naming them is the point: "R2" alone does not distinguish production's bucket
  # from a preview's, which is exactly the confusion that made a preview deploy
  # able to write into production's. Credentials are never read here.
  @doc false
  def announce_storage_backend do
    case Application.get_env(:core, :storage) do
      Stacks.Storage.R2 ->
        Logger.info(
          "storage backend: R2 (bucket: #{Application.get_env(:core, :r2_bucket) || "UNSET"})"
        )

      Stacks.Storage.Local ->
        Logger.warning(
          "storage backend: Local (upload_dir: #{Application.get_env(:core, :upload_dir) || "UNSET"}) " <>
            "— uploaded bytes live on this node's filesystem and do not survive its replacement"
        )

      other ->
        Logger.info("storage backend: #{inspect(other)}")
    end
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
