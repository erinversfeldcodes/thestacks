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
      {Plugins.Ecto, repos: tracked_repos()},
      {Plugins.Oban, oban_supervisors: [Oban]},
      Core.PromEx.Plugins.Stacks
    ]
  end

  # Only include Core.ObanRepo when Oban is configured to use it — same
  # rule as `Core.Application.oban_repo_child/0`. In test, Oban is routed
  # to Core.Repo and Core.ObanRepo is never started, so registering its
  # telemetry prefix would just listen for events that never fire.
  defp tracked_repos do
    case Application.fetch_env!(:core, Oban)[:repo] do
      Core.ObanRepo -> [Core.Repo, Core.ObanRepo]
      _ -> [Core.Repo]
    end
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
    # Dashboards-as-code (Issue #230). Registered with the `{:core, path}`
    # form so PromEx uploads them to Grafana when an instance is configured
    # (Issue #232). The JSON lives under `apps/core/priv/grafana/` and is
    # kept in lock-step with the registered metrics by
    # `Core.PromEx.DashboardDriftTest`. `datasource_id: "prometheus"` (see
    # `dashboard_assigns/0`) matches the datasource uid the panels query.
    [
      {:core, "grafana/moderation_agegate.json"},
      {:core, "grafana/auth_security.json"},
      {:core, "grafana/visibility_social.json"},
      {:core, "grafana/gdpr_data_rights.json"},
      {:core, "grafana/discovery.json"},
      {:core, "grafana/platform_ops.json"}
    ]
  end
end
