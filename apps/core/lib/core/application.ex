defmodule Core.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
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
          Stacks.CircuitBreakers,
          StacksWeb.Plugs.RateLimiter.Server,
          Stacks.AI.BudgetTracker,
          Stacks.Books.BookDetailCache,
          {Oban, Application.fetch_env!(:core, Oban)},
          CoreWeb.Telemetry,
          Core.PromEx,
          CoreWeb.Endpoint
        ] ++ pipeline_children()

    opts = [strategy: :one_for_one, name: Core.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Start Core.ObanRepo only when Oban is actually configured to use it.
  # In prod, config.exs points Oban at Core.ObanRepo for HTTP-handler /
  # background-worker pool isolation. In test, test.exs overrides Oban
  # back to Core.Repo (the multi-repo sandbox dance gets complicated),
  # so starting Core.ObanRepo there just adds a second idle pool that
  # doesn't interact cleanly with Ecto.Adapters.SQL.Sandbox.
  defp oban_repo_child do
    oban_repo = Application.fetch_env!(:core, Oban)[:repo]

    if oban_repo == Core.ObanRepo do
      [Core.ObanRepo]
    else
      []
    end
  end

  # Erlang clustering via libcluster — active only on Fly.io (FLY_APP_NAME present).
  # Phoenix.PubSub's pg adapter works across nodes once they are connected;
  # no PubSub config change is needed.
  defp cluster_children do
    topologies = Application.get_env(:libcluster, :topologies, [])

    if topologies == [] do
      []
    else
      [{Cluster.Supervisor, [topologies, [name: Core.ClusterSupervisor]]}]
    end
  end

  # Fly's internal .internal hostnames resolve to IPv6 (6PN) addresses only.
  # Without :inet6, Erlang's gen_tcp defaults to :inet (IPv4) and cannot dial
  # them — `:inet.getaddrs/2` returns `:nxdomain` because there's no A
  # record, only AAAA. Every in-cluster service URL must be added to this
  # list or its calls will fail silently from the caller's perspective.
  #
  # Discovered 2026-04-20 when SearXNG deps-check was returning
  # `%Mint.TransportError{reason: :nxdomain}` even though SearXNG was
  # healthy and DNS resolved fine from a shell (`getent hosts` worked
  # but Erlang's IPv4-only resolver didn't).
  defp finch_spec do
    vision_url = Application.get_env(:core, :vision_service_url, "http://localhost:8000")
    scraper_url = Application.get_env(:core, :scraper_service_url, "http://localhost:8080")
    searxng_url = Application.get_env(:core, :searxng_url, "http://localhost:8888")

    inet6_pool = [conn_opts: [transport_opts: [inet6: true]]]

    pools =
      [vision_url, scraper_url, searxng_url]
      |> Enum.filter(&String.contains?(&1, ".internal"))
      |> Map.new(&{&1, inet6_pool})

    {Finch, name: Stacks.Finch, pools: pools}
  end

  # Broadway pipelines run as supervised GenStage processes. In test mode,
  # their batch processors spawn in separate PIDs that don't have Ecto
  # sandbox access, causing intermittent DBConnection.OwnershipError.
  # Pipeline tests create their own named instances with sandbox-allowed PIDs.
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
