defmodule Stacks.Discovery.SearxngClient do
  @moduledoc """
  HTTP client for self-hosted SearXNG search.

  No rate limiting needed (self-hosted, unlimited).
  Uses Finch with the shared `Stacks.Finch` pool.
  Instance URL configured via `Application.get_env(:core, :searxng_url)`.

  Protected by `:searxng_fuse` — managed by `Stacks.CircuitBreakers`.
  When the fuse is blown (SearXNG is down or slow), requests
  short-circuit to `{:error, :circuit_open}` without touching the
  upstream. The probe loop confirms SearXNG is back and resets the
  fuse automatically.
  """

  @behaviour Stacks.Discovery.SearxngClientBehaviour

  require Logger

  @fuse_name :searxng_fuse

  @impl true
  @doc """
  Searches SearXNG for the given query.

  ## Options

    * `:limit` — maximum number of results (default: 5)

  Returns `{:ok, [%{title, url, description}]}` or `{:error, reason}`.
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) do
    base_url = Application.get_env(:core, :searxng_url)

    cond do
      is_nil(base_url) or base_url == "" ->
        Logger.warning("SearxngClient: SEARXNG_URL not configured")
        {:error, :url_not_configured}

      :fuse.ask(@fuse_name, :sync) == :blown ->
        {:error, :circuit_open}

      true ->
        do_search(base_url, query, opts)
    end
  end

  defp do_search(base_url, query, opts) do
    limit = Keyword.get(opts, :limit, 5)

    url =
      "#{base_url}/search?q=#{URI.encode(query)}&format=json&pageno=1&number_of_results=#{limit}"

    req =
      Finch.build(
        :get,
        url,
        [{"Accept", "application/json"}]
      )

    case Finch.request(req, Stacks.Finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        parse_results(body)

      {:ok, %Finch.Response{status: status, body: body}} when status >= 500 ->
        Logger.warning("SearxngClient: upstream 5xx #{status}: #{body}")
        Stacks.CircuitBreakers.melt(@fuse_name)
        {:error, {:unexpected_status, status}}

      {:ok, %Finch.Response{status: status, body: body}} ->
        # 4xx other than server errors — don't melt; likely a
        # misconfigured query, not a service-health signal.
        Logger.warning("SearxngClient: unexpected status #{status}: #{body}")
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        Logger.warning("SearxngClient: request failed: #{inspect(reason)}")
        Stacks.CircuitBreakers.melt(@fuse_name)
        {:error, reason}
    end
  end

  defp parse_results(body) do
    case Jason.decode(body) do
      {:ok, %{"results" => results}} when is_list(results) ->
        parsed =
          Enum.map(results, fn result ->
            %{
              title: Map.get(result, "title", ""),
              url: Map.get(result, "url", ""),
              description: Map.get(result, "content", "")
            }
          end)

        {:ok, parsed}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:json_decode_error, reason}}
    end
  end
end
