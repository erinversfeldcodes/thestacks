defmodule Stacks.Telemetry.Reporter do
  @moduledoc """
  Structured-log handler for the upload-pipeline phase spans and cache
  lookup events. Each event becomes a single `Logger.info` line with
  `key=value` pairs, making it trivially greppable in Fly logs for
  post-hoc p95 / hit-rate analysis.

  Events handled:

    * `[:stacks, :upload, :phase, :stop]` — phase span completed.
      Log shape: `upload_phase phase=<name> duration_ms=<N> upload_id=<id> …`

    * `[:stacks, :books, :isbn_resolver_cache, :lookup]`
    * `[:stacks, :books, :title_search_cache, :lookup]`
      Log shape: `cache_lookup cache=<name> tier=l1|l2 outcome=hit|miss`

  Attach once at boot (`Core.Application.start/2`). The handler IDs are
  unique per event so `:telemetry.detach/1` can remove individual hooks
  if needed.
  """

  require Logger

  @upload_phase_events [[:stacks, :upload, :phase, :stop]]
  @cache_events [
    [:stacks, :books, :isbn_resolver_cache, :lookup],
    [:stacks, :books, :title_search_cache, :lookup]
  ]

  @doc """
  Attach all reporter handlers. Safe to call multiple times — subsequent
  calls are no-ops because `:telemetry.attach/4` rejects duplicate IDs.
  """
  @spec attach() :: :ok
  def attach do
    attach_many("stacks-upload-phase", @upload_phase_events, &__MODULE__.handle_upload_phase/4)
    attach_many("stacks-cache-lookup", @cache_events, &__MODULE__.handle_cache_lookup/4)
    :ok
  end

  defp attach_many(id, events, handler) do
    case :telemetry.attach_many(id, events, handler, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_upload_phase(_event, measurements, metadata, _config) do
    duration_ms = native_to_ms(measurements[:duration])
    phase = metadata[:phase]
    upload_id = metadata[:upload_id]
    extras = metadata |> Map.drop([:phase, :upload_id, :telemetry_span_context]) |> kv_pairs()

    Logger.info(
      "upload_phase phase=#{phase} duration_ms=#{duration_ms} upload_id=#{upload_id} #{extras}"
    )
  end

  @doc false
  def handle_cache_lookup([_, _, cache, :lookup], _measurements, metadata, _config) do
    Logger.info(
      "cache_lookup cache=#{cache} tier=#{metadata[:tier]} outcome=#{metadata[:outcome]}"
    )
  end

  defp native_to_ms(nil), do: nil

  defp native_to_ms(native) do
    System.convert_time_unit(native, :native, :millisecond)
  end

  defp kv_pairs(map) when map_size(map) == 0, do: ""

  defp kv_pairs(map) do
    map
    |> Enum.map_join(" ", fn {k, v} ->
      "#{k}=#{inspect(v, limit: :infinity, printable_limit: 120)}"
    end)
  end
end
