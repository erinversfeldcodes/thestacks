defmodule Stacks.Enrichment.ScraperClient do
  @moduledoc """
  HTTP client for calling the Rust scraper service.

  Wire contract: `proto/stacks/internal/v1/scraper.proto`
  (ScrapeRequest/Response, ConfigReloadResponse)

  The actual implementation is swappable via Application env:
    config :core, :scraper_client, Stacks.Enrichment.ScraperClient       # real HTTP
    config :core, :scraper_client, Stacks.Enrichment.MockScraperClient  # tests

  ## Service-to-Service Authentication

  Requests use the same timestamp-based HMAC scheme as the vision service:
    - Header: `X-Internal-Token`
    - Value: `<unix_ts>.<HMAC-SHA256(secret, "<ts>.POST./scrape")>` (hex-encoded)
    - Secret: `SCRAPER_HMAC_SECRET` env var

  ## Circuit Breakers — two, covering different failure domains

  Both are consulted before a request and either being open yields
  `{:error, :circuit_open}`:

  - **`:scraper_fuse`** — the *sidecar* is unreachable or rejecting us. Shared by
    every store, which is right: if the service is down, no store can be scraped.
    Melted on a transport failure or an HTTP 401.
  - **`:scraper_store_fuse_<store>`** — *this shop* is failing: an upstream HTTP
    error, a rate limit, a missing config, or an extractor that cannot parse its
    pages. Melted on any other non-200, and on a
    `SCRAPE_OUTCOME_EXTRACTOR_FAILED` response.

  The split matters because the shared fuse opens for 15 minutes after 3 failures.
  Previously every failure melted it, so one bad shop stopped price scraping for
  all of them — repeatedly, since most causes recur on every attempt.

  Note what does **not** melt anything: `NOT_STOCKED` and `ROBOTS_BLOCKED` are
  determinations, not failures, and arrive as HTTP 200 (see
  `ScrapeOutcome` in the proto).
  """

  @behaviour Stacks.Enrichment.ScraperClientBehaviour

  alias Stacks.CircuitBreakers
  alias Stacks.Proto.Scraper.ScrapeRequest

  require Logger

  @fuse_name :scraper_fuse

  @impl true
  def scrape(isbn, store_name), do: scrape(isbn, store_name, nil)

  @impl true
  def scrape(isbn, store_name, product_path) do
    case configured_client() do
      __MODULE__ -> do_scrape(isbn, store_name, product_path)
      client -> client.scrape(isbn, store_name, product_path)
    end
  end

  @impl true
  def catalogue_titles(store_name) do
    case configured_client() do
      __MODULE__ -> do_catalogue_titles(store_name)
      client -> client.catalogue_titles(store_name)
    end
  end

  # Bulk sweep, so only the service fuse gates it — same reasoning as the index build.
  defp do_catalogue_titles(store_name) do
    with :ok <- ask(@fuse_name) do
      path = "/catalogue/titles"

      req =
        Finch.build(
          :post,
          "#{base_url()}#{path}",
          [{"content-type", "application/json"}, {"X-Internal-Token", auth_token("POST", path)}],
          Jason.encode!(%{store: store_name})
        )

      req
      |> Finch.request(Stacks.Finch, receive_timeout: 600_000)
      |> handle_titles_response(store_name)
    end
  end

  defp handle_titles_response({:ok, %Finch.Response{status: 200, body: body}}, _store) do
    case Jason.decode(body) do
      {:ok, %{"titles" => titles}} when is_list(titles) -> {:ok, titles}
      _ -> {:error, :unexpected_response}
    end
  end

  defp handle_titles_response({:ok, %Finch.Response{status: status, body: body}}, store) do
    CircuitBreakers.melt(@fuse_name)
    Logger.warning("ScraperClient: catalogue titles HTTP #{status} for #{store}: #{body}")
    {:error, {:http, status}}
  end

  defp handle_titles_response({:error, reason}, store) do
    CircuitBreakers.melt(@fuse_name)
    Logger.warning("ScraperClient: catalogue titles failed for #{store}: #{inspect(reason)}")
    {:error, reason}
  end

  defp do_scrape(isbn, store_name, product_path) do
    store_fuse = CircuitBreakers.store_fuse(store_name)

    # Both domains must be healthy. Asking the service fuse first means a downed
    # sidecar short-circuits without allocating or consulting store state.
    with :ok <- ask(@fuse_name),
         :ok <- ask(store_fuse) do
      make_scraper_request(isbn, store_name, store_fuse, product_path)
    end
  end

  defp ask(fuse_name) do
    case :fuse.ask(fuse_name, :sync) do
      :ok -> :ok
      # `:not_found` can only happen if a fuse was never installed — treat it as
      # closed rather than blocking scrapes on a bookkeeping gap.
      {:error, :not_found} -> :ok
      :blown -> {:error, :circuit_open}
    end
  end

  # An HTTP 200 carrying EXTRACTOR_FAILED means the service worked and this store's
  # extraction did not — a per-store fault that should back off from this store
  # alone. NOT_STOCKED and ROBOTS_BLOCKED are determinations and melt nothing.
  defp melt_if_extractor_failed(
         {:ok, %{"outcome" => "SCRAPE_OUTCOME_EXTRACTOR_FAILED"}},
         store_fuse,
         isbn,
         store_name
       ) do
    CircuitBreakers.melt(store_fuse)

    Logger.warning(
      "ScraperClient: extraction failed for isbn=#{isbn} store=#{store_name}; melting #{store_fuse}"
    )

    :ok
  end

  defp melt_if_extractor_failed(_decoded, _store_fuse, _isbn, _store_name), do: :ok

  @impl true
  def fetch_page(store_name, path), do: fetch_page(store_name, path, [])

  @impl true
  def fetch_page(store_name, path, validators) do
    case configured_client() do
      __MODULE__ -> do_fetch_page(store_name, path, validators)
      client -> client.fetch_page(store_name, path, validators)
    end
  end

  # A single page fetch through the scraper's compliant egress — robots.txt, then the
  # rate limiter, then the request. Callers must never build their own HTTP request to
  # a store: `DiscoverBookstoreEventsJob` did (a bare Finch GET, no robots check, no
  # rate limit, no fuse), which is the hole this closes.
  #
  # Gated by BOTH fuses, unlike the bulk sweeps: this is a per-store read on a normal
  # cadence, so a store that is failing should stop being asked — exactly the case the
  # store fuse exists for.
  #
  # `{:error, {:robots_blocked, rule}}` is a *determination*, not a failure: the caller
  # records it and stops. Deliberately not melting either fuse, because a disallow
  # recurs on every attempt by definition and melting on it would take every other
  # store down with it.
  defp do_fetch_page(store_name, path, validators) do
    store_fuse = CircuitBreakers.store_fuse(store_name)

    with :ok <- ask(@fuse_name),
         :ok <- ask(store_fuse) do
      endpoint = "/fetch"

      Finch.build(
        :post,
        "#{base_url()}#{endpoint}",
        [
          {"content-type", "application/json"},
          {"X-Internal-Token", auth_token("POST", endpoint)}
        ],
        Jason.encode!(%{
          store: store_name,
          path: path,
          # Sent verbatim — an ETag is opaque, and reformatting one makes it stop matching silently.
          if_none_match: Keyword.get(validators, :etag) || "",
          if_modified_since: Keyword.get(validators, :last_modified) || ""
        })
      )
      |> Finch.request(Stacks.Finch, receive_timeout: 30_000)
      |> handle_fetch_response(store_name, store_fuse)
    end
  end

  @impl true
  def sitemap_urls(store_name) do
    case configured_client() do
      __MODULE__ -> do_sitemap_urls(store_name)
      client -> client.sitemap_urls(store_name)
    end
  end

  # Gated by both fuses like `fetch_page/2`: a per-store read on a normal cadence, so a store that is
  # failing should stop being asked.
  defp do_sitemap_urls(store_name) do
    store_fuse = CircuitBreakers.store_fuse(store_name)

    with :ok <- ask(@fuse_name),
         :ok <- ask(store_fuse) do
      endpoint = "/sitemap-urls"

      Finch.build(
        :post,
        "#{base_url()}#{endpoint}",
        [
          {"content-type", "application/json"},
          {"X-Internal-Token", auth_token("POST", endpoint)}
        ],
        Jason.encode!(%{store: store_name})
      )
      # Longer than `fetch_page`'s 30s: the walk fetches several documents and pauses between them
      # on purpose. The courtesy delay is the reason this needs room, not slowness.
      |> Finch.request(Stacks.Finch, receive_timeout: 120_000)
      |> handle_sitemap_response(store_name, store_fuse)
    end
  end

  defp handle_sitemap_response({:ok, %Finch.Response{status: 200, body: body}}, store, _fuse) do
    case classify_sitemap_body(body, store) do
      {:unexpected, other} ->
        CircuitBreakers.melt(@fuse_name)

        Logger.warning(
          "ScraperClient: unexpected sitemap response for #{store}: #{inspect(other)}"
        )

        {:error, :unexpected_response}

      result ->
        result
    end
  end

  defp handle_sitemap_response({:ok, %Finch.Response{status: status, body: body}}, store, fuse) do
    CircuitBreakers.melt(fuse)
    Logger.warning("ScraperClient: sitemap HTTP #{status} for #{store}: #{body}")
    {:error, {:http, status}}
  end

  defp handle_sitemap_response({:error, reason}, store, _fuse) do
    CircuitBreakers.melt(@fuse_name)
    Logger.warning("ScraperClient: sitemap walk failed for #{store}: #{inspect(reason)}")
    {:error, reason}
  end

  @doc """
  Maps a `/sitemap-urls` response body onto a result, without side effects.

  Public for the same reason as `classify_fetch_body/2`: tests swap this whole module out, so these
  branches are otherwise unreachable. `{:unexpected, _}` is the only return that melts a fuse.
  """
  @spec classify_sitemap_body(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()} | {:unexpected, term()}
  def classify_sitemap_body(body, store) do
    case Jason.decode(body) do
      {:ok, %{"outcome" => "SITEMAP_OUTCOME_HARVESTED"} = ok} ->
        # Every list is read with a default: the sidecar omits empty repeated fields
        # (`skip_serializing_if`), so an absent key means "none", not a malformed response.
        harvest = %{
          urls: Map.get(ok, "urls", []),
          skipped: Map.get(ok, "skipped", []),
          truncated: Map.get(ok, "truncated", false),
          documents_fetched: Map.get(ok, "documents_fetched", 0),
          bytes_read: Map.get(ok, "bytes_read", 0)
        }

        Logger.info(
          "ScraperClient: #{store} sitemap — #{length(harvest.urls)} url(s) from " <>
            "#{harvest.documents_fetched} document(s), #{harvest.bytes_read} bytes, " <>
            "#{length(harvest.skipped)} skipped#{if harvest.truncated, do: " (TRUNCATED)", else: ""}"
        )

        {:ok, harvest}

      # ⚠️ Its own error and NOT `{:ok, %{urls: []}}`. "The shop declares no sitemap" is a different
      # fact from "the sitemap listed nothing", and a caller that cannot tell them apart will record
      # a shop as having no events page without ever having looked.
      {:ok, %{"outcome" => "SITEMAP_OUTCOME_NO_SITEMAP_DECLARED"}} ->
        Logger.info("ScraperClient: #{store} declares no sitemap in robots.txt")
        {:error, :no_sitemap_declared}

      {:ok, %{"outcome" => "SITEMAP_OUTCOME_ROBOTS_BLOCKED"} = ok} ->
        rule = ok |> Map.get("skipped", []) |> List.first() || "disallowed"
        Logger.info("ScraperClient: robots.txt blocks #{store}'s sitemap (#{rule})")
        {:error, {:robots_blocked, rule}}

      {:ok, %{"outcome" => "SITEMAP_OUTCOME_RATE_LIMITED"} = ok} ->
        {:error, {:rate_limited, Map.get(ok, "retry_after_seconds", 60)}}

      other ->
        {:unexpected, other}
    end
  end

  # No `store_fuse` here: on a 200 the store answered, so nothing about it is failing.
  # An unrecognised outcome below is a client/sidecar contract mismatch, which melts the
  # *service* fuse — melting the store's would blame the shop for our own bug.
  defp handle_fetch_response({:ok, %Finch.Response{status: 200, body: body}}, store, _store_fuse) do
    case classify_fetch_body(body, store) do
      {:unexpected, other} ->
        CircuitBreakers.melt(@fuse_name)
        Logger.warning("ScraperClient: unexpected fetch response for #{store}: #{inspect(other)}")
        {:error, :unexpected_response}

      result ->
        result
    end
  end

  defp handle_fetch_response({:ok, %Finch.Response{status: 401}}, store, _store_fuse) do
    CircuitBreakers.melt(@fuse_name)
    Logger.warning("ScraperClient: fetch unauthorised for #{store} — check the shared secret")
    {:error, {:http, 401}}
  end

  defp handle_fetch_response(
         {:ok, %Finch.Response{status: status, body: body}},
         store,
         store_fuse
       ) do
    CircuitBreakers.melt(store_fuse)
    Logger.warning("ScraperClient: fetch HTTP #{status} for #{store}: #{body}")
    {:error, {:http, status}}
  end

  defp handle_fetch_response({:error, reason}, store, _store_fuse) do
    CircuitBreakers.melt(@fuse_name)
    Logger.warning("ScraperClient: fetch failed for #{store}: #{inspect(reason)}")
    {:error, reason}
  end

  @doc """
  Maps a `/fetch` response body onto a result, without side effects.

  Public and separate from `handle_fetch_response/3` **so the outcome branches can be tested at
  all.** Tests swap the whole module out for `MockScraperClient`, and there is no Finch stub in this
  project, so every branch below was unreachable from a test — including the one deciding whether a
  shop's answer melts the fuse shared by every other shop.

  Returns `{:unexpected, decoded}` rather than melting anything itself: which fuse an unrecognised
  outcome should melt is the caller's business, and keeping the classification pure is what makes it
  assertable. **`{:unexpected, _}` is the only return that melts a fuse** — so a test that a given
  outcome is *not* `{:unexpected, _}` is a test that it does not melt one.
  """
  @spec classify_fetch_body(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()} | {:unexpected, term()}
  def classify_fetch_body(body, store) do
    case Jason.decode(body) do
      {:ok, %{"outcome" => "FETCH_OUTCOME_ROBOTS_BLOCKED", "robots_rule" => rule}} ->
        Logger.info("ScraperClient: robots.txt blocks #{store} (#{rule})")
        {:error, {:robots_blocked, rule}}

      # The shop is pacing us. A determination, so **neither fuse melts** — same reasoning as
      # `:robots_blocked` above, and the reasoning matters more here because it recurs: while the
      # cooldown holds, every attempt gets this answer, so counting it against the shared fuse would
      # take price scraping down for every other shop, over and over.
      #
      # ⚠️ Note what the clause below this one does to an unrecognised outcome: it melts the
      # *service* fuse. So adding `FETCH_OUTCOME_RATE_LIMITED` to the sidecar without adding this
      # clause would have made a 429 strictly worse than before it was reported at all.
      {:ok, %{"outcome" => "FETCH_OUTCOME_RATE_LIMITED"} = ok} ->
        retry_after = Map.get(ok, "retry_after_seconds", 60)

        Logger.info(
          "ScraperClient: #{store} asked us to back off for #{retry_after}s; not retrying until then"
        )

        {:error, {:rate_limited, retry_after}}

      # ⚠️ Its own result, NOT `{:ok, %{body: ""}}`. A 304 says "what you have is current"; an empty
      # body says "the page is now blank", which for an events listing means every event was removed.
      # The caller must keep what it already had, and a caller that cannot tell these apart will
      # cheerfully delete the lot.
      {:ok, %{"outcome" => "FETCH_OUTCOME_NOT_MODIFIED"} = ok} ->
        {:ok,
         %{
           status: 304,
           not_modified: true,
           etag: Map.get(ok, "etag", ""),
           last_modified: Map.get(ok, "last_modified", "")
         }}

      {:ok, %{"outcome" => "FETCH_OUTCOME_FETCHED", "status" => status, "body" => page} = ok} ->
        # `sitemaps` rides along on every fetch because robots.txt was already read for compliance —
        # the shop has therefore already told us where its content index is, and asking separately
        # would cost it a request it should never have to serve.
        #
        # This is what lets a caller resolve a real path instead of guessing. A guess is expensive
        # for the shop: a Shopify 404 is a *styled* page, measured at 249,540 bytes on 2026-07-29,
        # while a sitemap index is ~10 KB and states exactly which pages exist.
        {:ok,
         %{
           status: status,
           body: page,
           sitemaps: Map.get(ok, "sitemaps", []),
           # Stored by the caller and sent back next time, which is the only thing that makes the
           # conditional request worth having — without the round trip closing, every fetch stays full
           # price for the shop.
           etag: Map.get(ok, "etag", ""),
           last_modified: Map.get(ok, "last_modified", "")
         }}

      # An unrecognised outcome is a contract mismatch between this client and the
      # sidecar, which is a service problem rather than a store problem.
      other ->
        {:unexpected, other}
    end
  end

  @impl true
  def build_index(store_name) do
    case configured_client() do
      __MODULE__ -> do_build_index(store_name)
      client -> client.build_index(store_name)
    end
  end

  # Only the service fuse gates this, not the store's. A store fuse opens because
  # *price lookups* are failing there, and rebuilding the index is often the fix — so
  # letting the store's own breaker block the repair would be self-defeating.
  defp do_build_index(store_name) do
    with :ok <- ask(@fuse_name) do
      # Minutes, not seconds: the sweep waits on the shop's rate limit by design.
      index_request(store_name)
      |> Finch.request(Stacks.Finch, receive_timeout: 600_000)
      |> handle_index_response(store_name)
    end
  end

  defp index_request(store_name) do
    path = "/index/build"

    Finch.build(
      :post,
      "#{base_url()}#{path}",
      [{"content-type", "application/json"}, {"X-Internal-Token", auth_token("POST", path)}],
      Jason.encode!(%{isbn: "", store: store_name})
    )
  end

  defp handle_index_response({:ok, %Finch.Response{status: 200, body: body}}, _store_name) do
    case Jason.decode(body) do
      {:ok, %{"entries" => n}} -> {:ok, n}
      _ -> {:error, :unexpected_response}
    end
  end

  defp handle_index_response({:ok, %Finch.Response{status: status, body: body}}, store_name) do
    # Service fuse only: an index build says nothing about one store's prices.
    CircuitBreakers.melt(@fuse_name)
    Logger.warning("ScraperClient: index build HTTP #{status} for #{store_name}: #{body}")
    {:error, {:http, status}}
  end

  defp handle_index_response({:error, reason}, store_name) do
    CircuitBreakers.melt(@fuse_name)
    Logger.warning("ScraperClient: index build failed for #{store_name}: #{inspect(reason)}")
    {:error, reason}
  end

  defp base_url do
    Application.get_env(:core, :scraper_service_url, "http://localhost:8080")
  end

  defp build_scraper_request(isbn, store_name, product_path) do
    path = "/scrape"
    url = "#{base_url()}#{path}"

    body =
      Jason.encode!(%ScrapeRequest{isbn: isbn, store: store_name, product_path: product_path})

    token = auth_token("POST", path)

    Finch.build(
      :post,
      url,
      [{"content-type", "application/json"}, {"X-Internal-Token", token}],
      body
    )
  end

  defp make_scraper_request(isbn, store_name, store_fuse, product_path) do
    req = build_scraper_request(isbn, store_name, product_path)
    # Telemetry :start is emitted here (after fuse gate) so every :start has a
    # matching :stop/:exception — necessary for handlers that track open spans.
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:stacks, :scraper, :request, :start],
      %{system_time: System.system_time()},
      %{isbn: isbn, store: store_name}
    )

    case Finch.request(req, Stacks.Finch, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:stacks, :scraper, :request, :stop],
          %{duration: duration},
          %{isbn: isbn, store: store_name, status: 200}
        )

        decoded = Jason.decode(resp_body)
        melt_if_extractor_failed(decoded, store_fuse, isbn, store_name)
        decoded

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:stacks, :scraper, :request, :stop],
          %{duration: duration},
          %{isbn: isbn, store: store_name, status: status}
        )

        # A 401 means our HMAC is wrong, which is true of every store — that is a
        # service problem. Everything else non-200 is store-specific after the
        # outcome split: an upstream HTTP error, a rate limit, a missing or invalid
        # config for this store. Melting the shared fuse for those is what let one
        # shop stop all twelve.
        CircuitBreakers.melt(if status == 401, do: @fuse_name, else: store_fuse)

        Logger.warning("ScraperClient: HTTP #{status} for isbn=#{isbn} store=#{store_name}")
        {:error, %{status: status, body: resp_body}}

      {:error, reason} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:stacks, :scraper, :request, :exception],
          %{duration: duration},
          %{isbn: isbn, store: store_name, kind: :error, reason: reason}
        )

        # We never reached the sidecar, so this says nothing about any one store.
        CircuitBreakers.melt(@fuse_name)

        Logger.warning(
          "ScraperClient: request failed for isbn=#{isbn} store=#{store_name}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp auth_token(method, path) do
    ts = System.os_time(:second) |> Integer.to_string()
    secret = Application.fetch_env!(:core, :scraper_hmac_secret)
    message = "#{ts}.#{method}.#{path}"
    sig = :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode16(case: :lower)
    "#{ts}.#{sig}"
  end

  defp configured_client do
    Application.get_env(:core, :scraper_client, __MODULE__)
  end
end
