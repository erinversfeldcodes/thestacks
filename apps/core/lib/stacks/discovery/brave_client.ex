defmodule Stacks.Discovery.BraveClient do
  @moduledoc """
  Real HTTP client for Brave Search API.

  Rate limited to ~67 queries/day (2000/month free tier).
  Uses Finch with the shared `Stacks.Finch` pool.
  API key configured via `Application.get_env(:core, :brave_search_api_key)`.

  Protected by `:brave_fuse` — managed by `Stacks.CircuitBreakers`. When
  the fuse is blown (Brave is rate-limiting us, 5xx'ing, or off-budget),
  requests short-circuit to `{:error, :circuit_open}` without touching
  the upstream. `Stacks.CircuitBreakers` runs a periodic probe against
  Brave's API and resets the fuse as soon as it's healthy again.
  """

  @behaviour Stacks.Discovery.BraveClientBehaviour

  require Logger

  @base_url "https://api.search.brave.com/res/v1/web/search"
  @daily_budget 67
  @fuse_name :brave_fuse

  @impl true
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) do
    with :ok <- check_fuse(),
         :ok <- check_daily_budget() do
      do_search(query, opts)
    end
  end

  # Ask the fuse first — short-circuit without spending budget or network
  # when we know Brave is unhealthy. `CircuitBreakers.melt/1` trips the
  # fuse when `do_search/2` actually fails upstream, so the loop is
  # self-healing and self-breaking.
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

      case Finch.request(req, Stacks.Finch, receive_timeout: 15_000) do
        {:ok, %Finch.Response{status: 200, body: body}} ->
          increment_daily_counter()
          parse_results(body)

        {:ok, %Finch.Response{status: 429}} ->
          Logger.warning("BraveClient: rate limited by Brave API")
          Stacks.CircuitBreakers.melt(@fuse_name)
          {:error, :rate_limited}

        {:ok, %Finch.Response{status: status, body: body}} when status >= 500 ->
          Logger.warning("BraveClient: upstream 5xx #{status}: #{inspect(body)}")
          Stacks.CircuitBreakers.melt(@fuse_name)
          {:error, {:unexpected_status, status}}

        {:ok, %Finch.Response{status: status, body: body}} ->
          # 4xx other than 429 (e.g. 401, 403, 400) — don't melt; likely
          # a misconfigured request, not a service-health signal. Surface
          # the error so callers see it but keep the fuse closed.
          Logger.warning("BraveClient: unexpected status #{status}: #{inspect(body)}")
          {:error, {:unexpected_status, status}}

        {:error, reason} ->
          Logger.warning("BraveClient: request failed: #{inspect(reason)}")
          Stacks.CircuitBreakers.melt(@fuse_name)
          {:error, reason}
      end
    end
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

  # Daily budget tracking via :counters (atomic, no global GC).
  # The counter resets when the date changes.
  defp check_daily_budget do
    today = Date.utc_today()
    {date, count} = get_counter()

    if date == today and count >= @daily_budget do
      {:error, :daily_budget_exhausted}
    else
      :ok
    end
  end

  defp increment_daily_counter do
    today = Date.utc_today()
    {stored_date, _count} = get_counter()

    if stored_date != today do
      # Date changed — reset the counter
      counter = :counters.new(1, [:atomics])
      :counters.add(counter, 1, 1)
      :persistent_term.put({__MODULE__, :daily_counter}, {today, counter})
    else
      {_date, counter} = :persistent_term.get({__MODULE__, :daily_counter})
      :counters.add(counter, 1, 1)
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
