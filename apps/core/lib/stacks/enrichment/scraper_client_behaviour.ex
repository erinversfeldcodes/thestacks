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
  Fetch one page from a configured store through the compliant egress.

  The **only** sanctioned way to retrieve a store's page. Building an HTTP request to
  a store directly bypasses robots.txt, the rate limiter and the circuit breakers —
  which is precisely what `DiscoverBookstoreEventsJob` used to do.

  `path` must be relative and begin with `/`. Only stores with a scraper config can be
  fetched: no config means no declared crawl policy, and guessing one is how a hard
  rule becomes advisory.

  `{:error, {:robots_blocked, rule}}` is a determination, not a failure — the caller
  must record it and stop rather than retry or fall back to another path. `rule` is the
  `Disallow:` line responsible, so a narrow block can be told from a total one.
  """
  @callback fetch_page(store_name :: String.t(), path :: String.t()) ::
              {:ok, %{status: integer(), body: String.t()}}
              | {:error, {:robots_blocked, String.t()} | term()}

  @doc """
  The pages a store lists in its own sitemap.

  The polite alternative to guessing at paths. A guess costs the shop a full page render — a Shopify
  404 measured 249,540 bytes — whereas the sitemap index is ~10 KB and states which pages exist.

  Bounded by a crawl budget in the sidecar (requests **and** bytes), and it never fetches a
  catalogue-sized child sitemap. `skipped` reports what was deliberately not fetched, so
  "found nothing" can be told from "declined to look".

  ⚠️ `{:ok, %{urls: []}}` and `{:error, :no_sitemap_declared}` are different facts. The first means
  the shop's index listed nothing usable; the second means it has no index at all. Recording either
  as the other marks a shop as having no events page without that ever having been established.

  `truncated: true` means the budget ended the walk early, so `urls` is incomplete.
  """
  @callback sitemap_urls(store_name :: String.t()) ::
              {:ok,
               %{
                 urls: [String.t()],
                 skipped: [String.t()],
                 truncated: boolean(),
                 documents_fetched: integer(),
                 bytes_read: integer()
               }}
              | {:error,
                 :no_sitemap_declared
                 | {:robots_blocked, String.t()}
                 | {:rate_limited, integer()}
                 | term()}

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
