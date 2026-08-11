defmodule Stacks.Monitoring do
  @moduledoc """
      Context for monitoring features: source health checks.

      Tracks the operational health of external data sources (scrapers, review
      sources, RSS feeds, event sources, LLM outputs) by recording successes and
      failures. Status is auto-computed from consecutive failure count:

      - 0-2 consecutive failures: `healthy`
      - 3-6 consecutive failures: `degraded`
      - 7+ consecutive failures: `broken`
  """

  require Logger

  import Ecto.Changeset
  import Ecto.Query

  alias Core.Repo
  alias Stacks.Events
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

  @doc """
      Records a successful check for the given source.

      Upserts by `source_name`: resets `consecutive_failures` to 0, increments
      `total_successes`, sets `last_success_at` to now, and marks status as
      `"healthy"`.

      Emits a `source_health.recorded` event after persisting.
  """
  @spec record_success(String.t(), String.t()) ::
          {:ok, SourceHealthCheck.t()} | {:error, Ecto.Changeset.t()}
  def record_success(source_name, source_type)
      when is_binary(source_name) and is_binary(source_type) do
    {:ok, check} = get_or_create(source_name, source_type)
    now = DateTime.utc_now()

    attrs = %{
      last_success_at: now,
      consecutive_failures: 0,
      total_successes: (check.total_successes || 0) + 1,
      status: "healthy"
    }

    result =
      check
      |> change_source_health_check(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        emit_health_event(updated)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
      Records a failed check for the given source.

      Upserts by `source_name`: increments `consecutive_failures` and
      `total_failures`, sets `last_failure_at` and `last_failure_reason`,
      and auto-computes status based on the new consecutive failure count.

      Emits a `source_health.recorded` event after persisting.
  """
  @spec record_failure(String.t(), String.t(), String.t()) ::
          {:ok, SourceHealthCheck.t()} | {:error, Ecto.Changeset.t()}
  def record_failure(source_name, source_type, reason)
      when is_binary(source_name) and is_binary(source_type) and is_binary(reason) do
    {:ok, check} = get_or_create(source_name, source_type)
    now = DateTime.utc_now()

    new_consecutive = (check.consecutive_failures || 0) + 1

    attrs = %{
      last_failure_at: now,
      last_failure_reason: reason,
      consecutive_failures: new_consecutive,
      total_failures: (check.total_failures || 0) + 1,
      status: compute_status(new_consecutive)
    }

    result =
      check
      |> change_source_health_check(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        emit_health_event(updated)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
      Finds a source health check by `source_name` or creates one with healthy
      defaults.
  """
  @spec get_or_create(String.t(), String.t()) ::
          {:ok, SourceHealthCheck.t()} | {:error, Ecto.Changeset.t()}
  def get_or_create(source_name, source_type)
      when is_binary(source_name) and is_binary(source_type) do
    case Repo.one(
           from(s in SourceHealthCheck,
             where: s.source_name == ^source_name
           )
         ) do
      nil ->
        %SourceHealthCheck{}
        |> change_source_health_check(%{
          source_name: source_name,
          source_type: source_type,
          status: "healthy",
          consecutive_failures: 0,
          total_successes: 0,
          total_failures: 0
        })
        |> Repo.insert()

      check ->
        {:ok, check}
    end
  end

  @doc """
      Lists all source health checks in the wire shape the admin scraper-health
      page (`Api.getSourceHealth`) consumes:
      `{name, source_type, status, consecutive_failures, last_success_at, last_failure_at}`
      with plain-string `source_type`/`status` and ISO8601-or-nil timestamps.
      `source_name` is remapped to the `name` key the decoder reads.
  """
  @spec list_source_health() :: [map()]
  def list_source_health do
    SourceHealthCheck
    |> order_by(asc: :source_name)
    |> Repo.all()
    |> Enum.map(&to_wire/1)
  end

  @doc """
      Computes the health status from the consecutive failure count.

      - 0-2: `"healthy"`
      - 3-6: `"degraded"`
      - 7+:  `"broken"`
  """
  @spec compute_status(non_neg_integer()) :: String.t()
  def compute_status(consecutive_failures) when consecutive_failures <= 2, do: "healthy"
  def compute_status(consecutive_failures) when consecutive_failures <= 6, do: "degraded"
  def compute_status(_consecutive_failures), do: "broken"

  defp to_wire(%SourceHealthCheck{} = check) do
    %{
      name: check.source_name,
      source_type: check.source_type,
      status: check.status,
      consecutive_failures: check.consecutive_failures,
      last_success_at: iso8601(check.last_success_at),
      last_failure_at: iso8601(check.last_failure_at)
    }
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp emit_health_event(%SourceHealthCheck{} = check) do
    Events.emit_safe(%{
      event_type: "source_health.recorded",
      aggregate_type: "source_health_check",
      aggregate_id: check.id,
      payload: %{
        source_name: check.source_name,
        source_type: check.source_type,
        status: check.status,
        consecutive_failures: check.consecutive_failures
      },
      metadata: %{actor: "system:monitoring"}
    })
  end
end
