defmodule Core.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Core.Repo,
      {Phoenix.PubSub, name: Core.PubSub},
      {Finch, name: Stacks.Finch},
      StacksWeb.Plugs.RateLimiter.Server,
      Stacks.AI.BudgetTracker,
      {Oban, Application.fetch_env!(:core, Oban)},
      CoreWeb.Telemetry,
      CoreWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Core.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    CoreWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
