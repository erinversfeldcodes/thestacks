defmodule Core.Application do
  @moduledoc false

  use Application

  alias Stacks.Workers.RefreshCostsJob

  @impl true
  def start(_type, _args) do
    children = [
      Core.Repo,
      Stacks.Vault,
      {Phoenix.PubSub, name: Core.PubSub},
      finch_spec(),
      StacksWeb.Plugs.RateLimiter.Server,
      Stacks.AI.BudgetTracker,
      {Oban, Application.fetch_env!(:core, Oban)},
      CoreWeb.Telemetry,
      CoreWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Core.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Enqueue RefreshCostsJob shortly after startup so cost data is populated
    # immediately after a deploy. Delayed to ensure Oban is fully initialized.
    # The daily cron keeps it fresh after that.
    if match?({:ok, _}, result) do
      Task.start(fn ->
        Process.sleep(5_000)
        Oban.insert(RefreshCostsJob.new(%{}))
      end)
    end

    result
  end

  # Fly's internal .internal hostnames resolve to IPv6 (6PN) addresses only.
  # Without :inet6, Erlang's gen_tcp defaults to :inet (IPv4) and cannot dial
  # them. We detect internal URLs at startup and configure the pool accordingly.
  defp finch_spec do
    vision_url = Application.get_env(:core, :vision_service_url, "http://localhost:8000")

    pools =
      if String.contains?(vision_url, ".internal") do
        %{vision_url => [conn_opts: [transport_opts: [inet6: true]]]}
      else
        %{}
      end

    {Finch, name: Stacks.Finch, pools: pools}
  end

  @impl true
  def config_change(changed, _new, removed) do
    CoreWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
