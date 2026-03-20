defmodule Stacks.Discovery.SearxngClient do
  @moduledoc """
  HTTP client for self-hosted SearXNG search.

  No rate limiting needed (self-hosted, unlimited).
  Uses Finch with the shared `Stacks.Finch` pool.
  Instance URL configured via `Application.get_env(:core, :searxng_url)`.
  """

  @behaviour Stacks.Discovery.SearxngClientBehaviour

  require Logger

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

    if is_nil(base_url) or base_url == "" do
      Logger.warning("SearxngClient: SEARXNG_URL not configured")
      {:error, :url_not_configured}
    else
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

      {:ok, %Finch.Response{status: status, body: body}} ->
        Logger.warning("SearxngClient: unexpected status #{status}: #{body}")
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        Logger.warning("SearxngClient: request failed: #{inspect(reason)}")
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
