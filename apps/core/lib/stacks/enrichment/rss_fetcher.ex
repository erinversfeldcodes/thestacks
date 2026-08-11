defmodule Stacks.Enrichment.RssFetcher do
  @moduledoc """
    Real RSS feed fetcher.

    `fetch_and_parse/1` GETs the feed URL and parses the XML body with
    ElixirFeedParser. `probe/1` HEADs a candidate URL to ask only whether a feed
    is there. Both return `{:ok, _}` or `{:error, reason}`.

    This module is the single place the application talks HTTP to a feed URL, so
    swapping `config:core,:rss_fetcher` in test keeps the whole suite off the
    network. Anything added here must be reachable through the behaviour, or the
    seam leaks.
  """

  @behaviour Stacks.Enrichment.RssFetcherBehaviour

  require Logger

  @probe_receive_timeout 5_000
  @probe_request_timeout 5_000
  @fetch_receive_timeout 15_000
  @fetch_request_timeout 20_000

  @doc """
    The transport bounds each operation ships with, as passed to `Finch.request/3`.

    Public, and the call sites below read it rather than restating the values — that is what lets a
    test assert the bounds **structurally**. The tests used to prove them with a stopwatch instead
    ("a stalled peer returns within 20s"), which charged scheduler starvation to this module: observed
    at 28,569ms and 33,041ms under a loaded machine, then 3/3 green idle. A wall clock cannot
    tell a missing bound from a busy box. Now the structural test pins these defaults, and the
    behavioural tests inject tiny bounds through the `opts` seam so their own stopwatches get 10×
    headroom instead of 1.5×.
  """
  @spec request_opts(:probe | :fetch) :: keyword()
  def request_opts(:probe),
    do: [receive_timeout: @probe_receive_timeout, request_timeout: @probe_request_timeout]

  def request_opts(:fetch),
    do: [receive_timeout: @fetch_receive_timeout, request_timeout: @fetch_request_timeout]

  @spec fetch_and_parse(String.t()) :: {:ok, map()} | {:error, term()}
  @impl true
  def fetch_and_parse(feed_url), do: fetch_and_parse(feed_url, [])

  @doc """
    As `fetch_and_parse/1`, with transport-bound overrides merged over `request_opts(:fetch)`.

    The seam exists for the transport-bound tests, which need real bounds at unreal sizes; production
    callers use the 1-arity behaviour callback and never pass options.
  """
  @spec fetch_and_parse(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_and_parse(feed_url, opts) do
    req = Finch.build(:get, feed_url)

    case Finch.request(req, Stacks.Finch, Keyword.merge(request_opts(:fetch), opts)) do
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
  def probe(url), do: probe(url, [])

  @doc "As `probe/1`, with transport-bound overrides — see `fetch_and_parse/2`."
  @spec probe(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def probe(url, opts) do
    req = Finch.build(:head, url)

    case Finch.request(req, Stacks.Finch, Keyword.merge(request_opts(:probe), opts)) do
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
