defmodule Stacks.Enrichment.RssFetcherBehaviour do
  @moduledoc "Behaviour for fetching and parsing RSS feeds — allows test mocking via Application env."

  @doc "Fetch an RSS feed from `url` and return parsed feed data."
  @callback fetch_and_parse(url :: String.t()) :: {:ok, map()} | {:error, term()}
end
