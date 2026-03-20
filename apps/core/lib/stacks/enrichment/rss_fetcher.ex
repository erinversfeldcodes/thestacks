defmodule Stacks.Enrichment.RssFetcher do
  @moduledoc """
  Real RSS feed fetcher.

  Uses Finch to GET the feed URL and ElixirFeedParser to parse the XML body.
  Returns `{:ok, feed_map}` on success or `{:error, reason}` on failure.
  """

  @behaviour Stacks.Enrichment.RssFetcherBehaviour

  @spec fetch_and_parse(String.t()) :: {:ok, map()} | {:error, term()}
  @impl true
  def fetch_and_parse(feed_url) do
    req = Finch.build(:get, feed_url)

    case Finch.request(req, Stacks.Finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        parse_feed(body)

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:fetch_error, Exception.message(e)}}
  end

  @spec parse_feed(String.t()) :: {:ok, map()} | {:error, term()}
  defp parse_feed(xml_body) do
    case ElixirFeedParser.parse(xml_body) do
      {:ok, feed} -> {:ok, feed}
      {:error, reason} -> {:error, {:parse_error, reason}}
    end
  rescue
    e -> {:error, {:parse_error, Exception.message(e)}}
  end
end
