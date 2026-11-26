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

      # ⛔ These two used to be ONE catch-all returning `{:error, :not_found}`,
      # and collapsing them cost more than legibility.
      #
      # Every outcome landed on the same atom: a 404, a 500, a refused
      # connection, a DNS failure, and a request_timeout. `RSSLivenessJob` passes
      # this reason straight into `Monitoring.record_failure/3` as
      # `inspect(reason)`, so every RSS failure on every author feed recorded
      # `:not_found` — a feed that is merely slow was indistinguishable from one
      # that does not exist, which is the difference between "retry" and "stop
      # asking".
      #
      # ⚠️ It also left this module's own transport-bound tests with nothing
      # structural to assert. "Did the 1s request_timeout fire?" had no answer in
      # the return value, so the test fell back to a WALL CLOCK — and a wall
      # clock cannot tell a missing bound from a busy machine. That test failed
      # at 11,821ms against a 10,000ms ceiling under load while being 3/3 green
      # idle, exactly as this module's moduledoc had predicted in prose.
      {:ok, %Finch.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:transport, transport_reason(reason)}}
    end
  rescue
    e ->
      Logger.warning("RssFetcher: feed probe failed for #{url}: #{Exception.message(e)}")
      {:error, :request_failed}
  end

  # The reason a transport error carries, so a caller can tell a timeout from a
  # refusal. Finch wraps both in a struct and only this field separates them.
  #
  # ⚠️ ONE CLAUSE, because dialyzer proved a second one dead. A defensive
  # pass-through fallback was written here first; `Finch.request/3` can only fail
  # with `Finch.Error`, `Finch.HTTPError` or `Finch.TransportError`, every one of
  # which has `:reason`, so the fallback could never match
  # (`pattern_match_cov`). Deleted rather than silenced: an unreachable clause
  # reads as a handled case and is the opposite of handling it.
  defp transport_reason(%{reason: reason}), do: reason

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
