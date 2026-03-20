defmodule Stacks.Monitoring do
  @moduledoc """
  Context for monitoring features: source health checks.
  """

  import Ecto.Changeset

  alias Stacks.Monitoring.SourceHealthCheck

  @valid_source_types ~w(scraper_config review_source rss_feed event_source llm_output)
  @valid_statuses ~w(healthy degraded broken)

  @required_fields [:source_name, :source_type, :status]
  @optional_fields [
    :last_success_at,
    :last_failure_at,
    :last_failure_reason,
    :consecutive_failures,
    :total_successes,
    :total_failures
  ]

  @doc "Changeset for creating or updating a source health check."
  @spec change_source_health_check(SourceHealthCheck.t(), map()) :: Ecto.Changeset.t()
  def change_source_health_check(%SourceHealthCheck{} = check, attrs) do
    check
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:source_type, @valid_source_types)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:source_name)
  end
end
