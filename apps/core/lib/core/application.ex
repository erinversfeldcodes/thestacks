defmodule Core.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Core.Repo,
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

  # Fly's internal .internal hostnames resolve to IPv6 (6PN) addresses only.
  # Without :inet6, Erlang's gen_tcp defaults to :inet (IPv4) and cannot dial
  # them. We detect internal URLs at startup and configure pools accordingly.
  defp finch_spec do
    vision_url = Application.get_env(:core, :vision_service_url, "http://localhost:8000")
    scraper_url = Application.get_env(:core, :scraper_service_url, "http://localhost:8080")

    inet6_pool = [conn_opts: [transport_opts: [inet6: true]]]

    pools =
      [vision_url, scraper_url]
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
