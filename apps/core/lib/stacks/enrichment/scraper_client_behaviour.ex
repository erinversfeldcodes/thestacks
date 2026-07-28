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

  @doc """
  Titles of products this store lists that carry no extractable ISBN.

  The residual for shops where no product carries an ISBN, so title matching is the
  only path. A bulk sweep: it waits on the shop's rate limit and takes minutes.
  """
  @callback catalogue_titles(store_name :: String.t()) ::
              {:ok, [%{String.t() => String.t()}]} | {:error, term()}

  @doc """
  Scrape a price, optionally telling the service where the product is.

  `product_path` is for the shops that carry no ISBN anywhere: the caller matched a
  title against its own catalogue and supplies the path, because the service cannot
  resolve an ISBN there at all.
  """
  @callback scrape(isbn :: String.t(), store_name :: String.t(), product_path :: String.t() | nil) ::
              {:ok, map()} | {:error, term()}

  @callback scrape(isbn :: String.t(), store_name :: String.t()) ::
              {:ok, map()} | {:error, term()}
end
