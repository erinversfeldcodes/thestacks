defmodule Stacks.Enrichment.RssFetcher do
  @moduledoc """
  Real RSS feed fetcher.

  `fetch_and_parse/1` GETs the feed URL and parses the XML body with
  ElixirFeedParser. `probe/1` HEADs a candidate URL to ask only whether a feed
  is there. Both return `{:ok, _}` or `{:error, reason}`.

  This module is the single place the application talks HTTP to a feed URL, so
  swapping `config :core, :rss_fetcher` in test keeps the whole suite off the
  network. Anything added here must be reachable through the behaviour, or the
  seam leaks (#377).
  """

  @behaviour Stacks.Enrichment.RssFetcherBehaviour

  require Logger

  # ⚠️ `receive_timeout` does NOT bound the request. Finch documents it as
  # "the maximum time to wait for EACH CHUNK to be received" — so a peer that
  # dribbles bytes resets it indefinitely. Measured on this codebase
  # (2026-08-03, Finch 0.23): a server emitting a 17-byte response one byte
  # every 2s ran for 35_017ms under `receive_timeout: 5_000` alone, and
  # returned in 8_028ms once `request_timeout: 8_000` was added. Only
  # `:request_timeout` bounds the whole response, and it defaults to
  # `:infinity`. Always set it alongside `receive_timeout`.
  #
  # The connect phase, by contrast, IS already bounded: Finch injects
  # `transport_opts[:timeout] = 5_000` when a pool does not set one
  # (`finch.ex` `valid_opts_to_map/1`). `Core.Application.finch_spec/0` now
  # pins that value explicitly rather than inheriting it.
  @probe_receive_timeout 5_000
  @probe_request_timeout 5_000
  @fetch_receive_timeout 15_000
  @fetch_request_timeout 20_000

  @spec fetch_and_parse(String.t()) :: {:ok, map()} | {:error, term()}
  @impl true
  def fetch_and_parse(feed_url) do
    req = Finch.build(:get, feed_url)

    case Finch.request(req, Stacks.Finch,
           receive_timeout: @fetch_receive_timeout,
           request_timeout: @fetch_request_timeout
         ) do
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

  @doc """
  HEAD `url` to see whether a feed lives there, without downloading it.

  Returns `{:ok, url}` on a 2xx, `{:error, reason}` otherwise. Callers fan this
  out over several candidate paths, so every phase must be bounded — see the
  `receive_timeout` note above.
  """
  @spec probe(String.t()) :: {:ok, String.t()} | {:error, term()}
  @impl true
  def probe(url) do
    req = Finch.build(:head, url)

    case Finch.request(req, Stacks.Finch,
           receive_timeout: @probe_receive_timeout,
           request_timeout: @probe_request_timeout
         ) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        {:ok, url}

      _ ->
        {:error, :not_found}
    end
  rescue
    e ->
      Logger.warning("RssFetcher: feed probe failed for #{url}: #{Exception.message(e)}")
      {:error, :request_failed}
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
