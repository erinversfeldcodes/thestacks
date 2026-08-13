defmodule Stacks.Discovery.BraveClient do
  @moduledoc """
      Real HTTP client for Brave Search API.

      Rate limited to ~67 queries/day (2000/month free tier).
      Uses Finch with the shared `Stacks.Finch` pool.
      API key configured via `Application.get_env(:core,:brave_search_api_key)`.

      Protected by `:brave_fuse` — managed by `Stacks.CircuitBreakers`. When
      the fuse is blown (Brave is rate-limiting us, 5xx'ing, or off-budget),
      requests short-circuit to `{:error,:circuit_open}` without touching
      the upstream. `Stacks.CircuitBreakers` runs a periodic probe against
      Brave's API and resets the fuse as soon as it's healthy again.
  """

  @behaviour Stacks.Discovery.BraveClientBehaviour

  require Logger

  @base_url "https://api.search.brave.com/res/v1/web/search"
  @daily_budget 200
  @fuse_name :brave_fuse

  @impl true
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) do
    with :ok <- check_fuse(),
         :ok <- check_daily_budget() do
      do_search(query, opts)
    end
  end

  defp check_fuse do
    case :fuse.ask(@fuse_name, :sync) do
      :ok -> :ok
      :blown -> {:error, :circuit_open}
    end
  end

  defp do_search(query, opts) do
    api_key = Application.get_env(:core, :brave_search_api_key)

    if is_nil(api_key) or api_key == "" do
      Logger.warning("BraveClient: BRAVE_SEARCH_API_KEY not configured")
      {:error, :api_key_missing}
    else
      limit = Keyword.get(opts, :limit, 5)
      url = "#{@base_url}?q=#{URI.encode(query)}&count=#{limit}"

      req =
        Finch.build(
          :get,
          url,
          [
            {"Accept", "application/json"},
            {"Accept-Encoding", "gzip"},
            {"X-Subscription-Token", api_key}
          ]
        )

      case Finch.request(req, Stacks.Finch, receive_timeout: 15_000, request_timeout: 20_000) do
        {:ok, %Finch.Response{status: 200, body: body, headers: headers}} ->
          increment_daily_counter()
          # one quota-consuming query — the cost page counts these
          :telemetry.execute([:stacks, :discovery, :brave_search], %{count: 1}, %{})
          parse_results(maybe_gunzip(body, headers))

        {:ok, %Finch.Response{status: 429}} ->
          Logger.warning("BraveClient: rate limited by Brave API")
          Stacks.CircuitBreakers.melt(@fuse_name)
          {:error, :rate_limited}

        {:ok, %Finch.Response{status: status, body: body}} when status >= 500 ->
          Logger.warning("BraveClient: upstream 5xx #{status}: #{inspect(body)}")
          Stacks.CircuitBreakers.melt(@fuse_name)
          {:error, {:unexpected_status, status}}

        {:ok, %Finch.Response{status: status, body: body}} ->
          Logger.warning("BraveClient: unexpected status #{status}: #{inspect(body)}")
          {:error, {:unexpected_status, status}}

        {:error, reason} ->
          Logger.warning("BraveClient: request failed: #{inspect(reason)}")
          Stacks.CircuitBreakers.melt(@fuse_name)
          {:error, reason}
      end
    end
  end

  # ⛔ We advertise `Accept-Encoding: gzip` and then have to actually decompress — Finch does not
  # do it for us. Without this, every Brave **200** reached `Jason.decode/1` holding gzip bytes and
  # returned `{:json_decode_error, ...}`, so `SourceDiscoveryJob` logged "Brave search failed" and
  # fell through to the SearXNG fallback. **Brave had therefore never once succeeded.**
  #
  # ⚠️ What made this invisible for so long is the fallback working. The primary path was dead and
  # the feature still produced rows, so nothing looked broken from the outside — the only signal was
  # a warning line among gzip bytes rendered as a byte list, which reads like noise. A fallback that
  # silently absorbs a broken primary is worse than no fallback: it converts an outage into a
  # permanent, unnoticed regression. Discovery ran entirely on the backup search engine.
  #
  # Keyed on the response header rather than sniffing magic bytes: the server tells us what it did,
  # and a `content-encoding` we do not handle should fail loudly rather than be guessed at.
  defp maybe_gunzip(body, headers) do
    gzipped? =
      Enum.any?(headers, fn {name, value} ->
        String.downcase(name) == "content-encoding" and
          String.contains?(String.downcase(value), "gzip")
      end)

    if gzipped?, do: :zlib.gunzip(body), else: body
  end

  defp parse_results(body) do
    case Jason.decode(body) do
      {:ok, %{"web" => %{"results" => results}}} when is_list(results) ->
        parsed =
          Enum.map(results, fn result ->
            %{
              title: Map.get(result, "title", ""),
              url: Map.get(result, "url", ""),
              description: Map.get(result, "description", "")
            }
          end)

        {:ok, parsed}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:json_decode_error, reason}}
    end
  end

  defp check_daily_budget do
    today = Date.utc_today()
    {date, count} = get_counter()

    if date == today and count >= @daily_budget do
      {:error, :daily_budget_exhausted}
    else
      :ok
    end
  end

  @doc """
      Records one Brave call against today's budget.

      ⚠️ **Public only so the fresh-node path is testable, and that is not a technicality.** This
      function crashed on the first live call in any fresh node (see the comment below), source
      discovery produced zero rows for weeks, and the cause was misattributed to a missing API key.
      Nothing exercised it: `brave_client_test.exs` covered only the *Mock* client, so the real
      counter had no coverage at all. A defect that reached production through an untested private
      function earns a seam.
  """
  @spec increment_daily_counter() :: :ok
  def increment_daily_counter do
    today = Date.utc_today()

    case :persistent_term.get({__MODULE__, :daily_counter}, nil) do
      {^today, counter} ->
        :counters.add(counter, 1, 1)

      _absent_or_stale ->
        counter = :counters.new(1, [:atomics])
        :counters.add(counter, 1, 1)
        :persistent_term.put({__MODULE__, :daily_counter}, {today, counter})
    end
  end

  defp get_counter do
    case :persistent_term.get({__MODULE__, :daily_counter}, nil) do
      nil -> {Date.utc_today(), 0}
      {date, counter} -> {date, :counters.get(counter, 1)}
    end
  rescue
    ArgumentError -> {Date.utc_today(), 0}
  end
end
