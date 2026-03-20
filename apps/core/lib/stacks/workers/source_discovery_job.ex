defmodule Stacks.Workers.SourceDiscoveryJob do
  @moduledoc """
  Oban worker that discovers new sources (bookshops, communities, etc.)
  via web search APIs.

  Uses BraveClient as the primary search backend. Falls back to SearxngClient
  when the Brave daily budget is exhausted. Deduplicates against existing
  sources by URL before creating new records.

  ## Args

    * `%{"query" => query, "location" => %{"city" => ..., "country_code" => ...}}` — single query
    * `%{"query" => query}` — query without location context

  Each newly created source is scored asynchronously via `ScoreSourceJob`.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.Discovery
  alias Stacks.Events
  alias Stacks.Workers.ScoreSourceJob

  @impl true
  def perform(%Oban.Job{args: %{"query" => query} = args}) do
    location = Map.get(args, "location")
    client = brave_client()

    case client.search(query, limit: 10) do
      {:ok, results} ->
        process_results(results, query, location)

      {:error, :daily_budget_exhausted} ->
        Logger.info("SourceDiscoveryJob: Brave budget exhausted, falling back to SearXNG")
        fallback_search(query, location)

      {:error, reason} ->
        Logger.warning("SourceDiscoveryJob: Brave search failed: #{inspect(reason)}")
        fallback_search(query, location)
    end
  end

  defp fallback_search(query, location) do
    client = searxng_client()

    case client.search(query, limit: 10) do
      {:ok, results} ->
        process_results(results, query, location)

      {:error, reason} ->
        Logger.warning("SourceDiscoveryJob: SearXNG fallback also failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp process_results(results, query, location) do
    discovered_via = build_discovered_via(query, location)

    new_sources =
      results
      |> Enum.reject(fn %{url: url} -> Discovery.get_source_by_url(url) != nil end)
      |> Enum.flat_map(fn result ->
        case create_source(result, discovered_via) do
          {:ok, source} -> [source]
          {:error, _} -> []
        end
      end)

    enqueue_scoring(new_sources)
    emit_event(new_sources, query)

    :ok
  end

  defp create_source(result, discovered_via) do
    Discovery.create_source(%{
      name: result.title,
      type: infer_type(result),
      url: result.url,
      discovered_via: discovered_via,
      status: :pending_review
    })
  end

  defp infer_type(%{title: title, description: description}) do
    text = String.downcase("#{title} #{description}")

    cond do
      String.contains?(text, "bookshop") or String.contains?(text, "bookstore") ->
        :bookshop

      String.contains?(text, "book club") or String.contains?(text, "reading group") ->
        :community

      String.contains?(text, "review") ->
        :review_site

      String.contains?(text, "event") or String.contains?(text, "festival") ->
        :event_source

      true ->
        :bookshop
    end
  end

  defp enqueue_scoring(sources) do
    Enum.each(sources, fn source ->
      case %{source_id: source.id}
           |> ScoreSourceJob.new()
           |> Oban.insert() do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "SourceDiscoveryJob: failed to enqueue scoring for source #{source.id}: #{inspect(reason)}"
          )
      end
    end)
  end

  defp emit_event([], _query), do: :ok

  defp emit_event(sources, query) do
    Events.emit_safe(%{
      event_type: "enrichment.sources_discovered",
      aggregate_type: "discovered_source",
      aggregate_id: List.first(sources).id,
      payload: %{
        count: length(sources),
        query: query,
        source_ids: Enum.map(sources, & &1.id)
      },
      metadata: %{actor: "system:source_discovery_job"}
    })
  end

  defp build_discovered_via(query, nil), do: "search:#{query}"

  defp build_discovered_via(query, %{"city" => city, "country_code" => cc}),
    do: "search:#{query} location:#{city},#{cc}"

  defp build_discovered_via(query, _), do: "search:#{query}"

  defp brave_client do
    Application.get_env(:core, :brave_client, Stacks.Discovery.BraveClient)
  end

  defp searxng_client do
    Application.get_env(:core, :searxng_client, Stacks.Discovery.SearxngClient)
  end
end
