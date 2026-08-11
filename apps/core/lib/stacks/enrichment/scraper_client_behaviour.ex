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
  Fetch one page from a configured store through the compliant egress —
  the ONLY sanctioned way to retrieve a store's page (direct HTTP bypasses
  robots.txt, the rate limiter and the fuses). `path` must be relative,
  starting `/`; stores without a scraper config cannot be fetched (no
  declared crawl policy). `{:error, {:robots_blocked, rule}}` is a
  determination, not a failure: record it and stop; `rule` is the
  responsible `Disallow:` line.
  """
  @callback fetch_page(store_name :: String.t(), path :: String.t()) ::
              {:ok, %{status: integer(), body: String.t()}}
              | {:error, {:robots_blocked, String.t()} | term()}

  @doc """
  As `fetch_page/2`, but sends cache validators so the shop can answer 304.

  `validators` is `[etag: String.t(), last_modified: String.t()]` from the previous fetch of the same
  path. A 304 returns `%{status: 304, not_modified: true}` — deliberately **not** a body of `""`,
  which would say the page went blank rather than that it is unchanged.
  """
  @callback fetch_page(
              store_name :: String.t(),
              path :: String.t(),
              validators :: keyword()
            ) ::
              {:ok, map()} | {:error, {:robots_blocked, String.t()} | term()}

  @doc """
  The pages a store lists in its own sitemap — the polite alternative to
  guessing paths (a Shopify 404 measured ~250KB; the sitemap index ~10KB).
  Budget-bounded in the sidecar (requests and bytes); `skipped` reports what
  was deliberately not fetched, `truncated: true` means the budget ended the
  walk early. ⚠️ `{:ok, %{urls: []}}` (index listed nothing usable) and
  `{:error, :no_sitemap_declared}` (no index at all) are different facts —
  never record one as the other.
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
