defmodule Stacks.Enrichment.ScraperClientBehaviour do
  @moduledoc "Behaviour for the scraper HTTP client — allows test mocking via Application env."

  @doc """
  Build a store's ISBN→product-path index.

  Separate from `scrape/2` because it is a bulk sweep: up to twenty requests against
  a shop limited to a few per minute, so it waits on the rate limiter and can take
  minutes. It must never run inside a price lookup.
  """
  @callback build_index(store_name :: String.t()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @callback scrape(isbn :: String.t(), store_name :: String.t()) ::
              {:ok, map()} | {:error, term()}
end
