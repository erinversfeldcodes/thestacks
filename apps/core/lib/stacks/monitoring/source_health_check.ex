defmodule Stacks.Monitoring.SourceHealthCheck do
  @moduledoc "Schema for op.source_health_checks — tracks the health of external data sources."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @derive {Jason.Encoder,
           only: [
             :id,
             :source_name,
             :source_type,
             :last_success_at,
             :last_failure_at,
             :last_failure_reason,
             :consecutive_failures,
             :total_successes,
             :total_failures,
             :status,
             :created_at,
             :updated_at
           ]}

  @type t :: %__MODULE__{}

  schema "source_health_checks" do
    field :source_name, :string
    field :source_type, :string
    field :last_success_at, :utc_datetime_usec
    field :last_failure_at, :utc_datetime_usec
    field :last_failure_reason, :string
    field :consecutive_failures, :integer, default: 0
    field :total_successes, :integer, default: 0
    field :total_failures, :integer, default: 0
    field :status, :string, default: "healthy"

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @required_fields [:source_name, :source_type, :status]
  @optional_fields [
    :last_success_at,
    :last_failure_at,
    :last_failure_reason,
    :consecutive_failures,
    :total_successes,
    :total_failures
  ]

  @valid_source_types ~w(scraper_config review_source rss_feed event_source llm_output)
  @valid_statuses ~w(healthy degraded broken)

  @doc "Changeset for creating or updating a source health check."
  def changeset(check, attrs) do
    check
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:source_type, @valid_source_types)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:source_name)
  end
end
