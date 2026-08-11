defmodule Stacks.Workers.DiscoverAuthorSourcesJob do
  @moduledoc """
  Oban worker that discovers author websites and RSS feeds via Brave Search.

  Accepts `%{"author_id" => id}` for a single author, or `%{"batch" => true}`
  to process all authors missing sources.

  For each author, searches Brave for their official website or blog,
  then attempts to discover an RSS feed at the discovered URL.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.Enrichment.Authors
  alias Stacks.Events

  @social_domains ~w(
    twitter.com x.com facebook.com instagram.com linkedin.com
    goodreads.com amazon.com wikipedia.org youtube.com tiktok.com
  )

  @impl true
  def perform(%Oban.Job{args: %{"author_id" => author_id}}) do
    case Authors.get_author(author_id) do
      nil ->
        Logger.warning("DiscoverAuthorSourcesJob: author #{author_id} not found")
        {:cancel, "author not found"}

      author ->
        discover_for_author(author)
    end
  end

  def perform(%Oban.Job{args: %{"batch" => true}}) do
    authors = Authors.authors_without_sources()
    Logger.info("DiscoverAuthorSourcesJob: processing #{length(authors)} authors in batch")

    Enum.each(authors, &discover_for_author/1)

    :ok
  end

  defp discover_for_author(author) do
    client = brave_client()
    query = ~s("#{author.name}" official website OR blog)

    case client.search(query, limit: 5) do
      {:ok, results} ->
        apply_discovered_sources(author, results)

      {:error, reason} ->
        Logger.warning(
          "DiscoverAuthorSourcesJob: search failed for author #{author.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp apply_discovered_sources(author, results) do
    website_url = extract_website_url(results)
    rss_feed_url = if website_url, do: discover_rss_feed(website_url)

    attrs =
      %{}
      |> maybe_put(:website_url, website_url, author.website_url)
      |> maybe_put(:rss_feed_url, rss_feed_url, author.rss_feed_url)

    if map_size(attrs) > 0 do
      persist_sources(author, attrs)
    else
      Logger.info("DiscoverAuthorSourcesJob: no new sources found for author #{author.id}")
      :ok
    end
  end

  defp persist_sources(author, attrs) do
    case Authors.update_author_sources(author, attrs) do
      {:ok, updated} ->
        Events.emit_safe(%{
          event_type: "enrichment.author_sources_discovered",
          aggregate_type: "author",
          aggregate_id: updated.id,
          payload: %{
            website_url: updated.website_url,
            rss_feed_url: updated.rss_feed_url
          },
          metadata: %{actor: "system:discover_author_sources_job"}
        })

        :ok

      {:error, reason} ->
        Logger.warning(
          "DiscoverAuthorSourcesJob: failed to update author #{author.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp extract_website_url(results) do
    results
    |> Enum.reject(fn %{url: url} -> social_media_url?(url) end)
    |> List.first()
    |> case do
      nil -> nil
      %{url: url} -> url
    end
  end

  defp social_media_url?(url) do
    uri = URI.parse(url)
    host = uri.host || ""
    Enum.any?(@social_domains, fn domain -> String.contains?(host, domain) end)
  end

  @feed_paths ["/feed", "/rss", "/feed.xml", "/rss.xml", "/atom.xml", "/blog/feed"]

  defp discover_rss_feed(website_url) do
    uri = URI.parse(website_url)
    base = "#{uri.scheme}://#{uri.host}"
    fetcher = rss_fetcher()

    Enum.find_value(@feed_paths, fn path ->
      feed_url = base <> path

      case fetcher.probe(feed_url) do
        {:ok, _} -> feed_url
        _ -> nil
      end
    end)
  end

  defp maybe_put(attrs, key, value, existing) do
    if value && is_nil(existing) do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end

  defp brave_client do
    Application.get_env(:core, :brave_client, Stacks.Discovery.BraveClient)
  end

  defp rss_fetcher do
    Application.get_env(:core, :rss_fetcher, Stacks.Enrichment.RssFetcher)
  end
end
