defmodule Stacks.Enrichment.RssFetcherBehaviour do
  @moduledoc "Behaviour for fetching and parsing RSS feeds — allows test mocking via Application env."

  @doc "Fetch an RSS feed from `url` and return parsed feed data."
  @callback fetch_and_parse(url :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc """
      Check whether a feed exists at `url` without downloading it (HTTP HEAD).

      Part of this behaviour rather than a second seam so that everything which
      talks HTTP to a feed URL is swapped by one config key (`:rss_fetcher`), and
      so no test can reach a real host through the discovery path.
  """
  @callback probe(url :: String.t()) :: {:ok, String.t()} | {:error, term()}
end
