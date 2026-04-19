defmodule Core.PromEx do
  @moduledoc """
  PromEx configuration for The Stacks.

  Bundles automatic Ecto, Phoenix, Oban, and BEAM telemetry alongside
  custom metrics for vision requests, fuse state, budget tracking, and
  cost recording. Exposes `/internal/metrics` in Prometheus text format.
  """

  use PromEx, otp_app: :core

  alias PromEx.Plugins

  @impl true
  def plugins do
    [
      Plugins.Application,
      Plugins.Beam,
      {Plugins.Phoenix, router: CoreWeb.Router, endpoint: CoreWeb.Endpoint},
      {Plugins.Ecto, repos: [Core.Repo]},
      {Plugins.Oban, oban_supervisors: [Oban]},
      Core.PromEx.Plugins.Stacks
    ]
  end

  @impl true
  def dashboard_assigns do
    [
      datasource_id: "prometheus",
      default_selected_interval: "30s"
    ]
  end

  @impl true
  def dashboards do
    []
  end
end
