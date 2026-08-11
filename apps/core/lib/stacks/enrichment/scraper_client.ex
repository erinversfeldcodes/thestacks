defmodule Stacks.Enrichment.ScraperClient do
  @moduledoc """
  HTTP client for the Rust scraper service. Wire contract:
  `proto/stacks/internal/v1/scraper.proto`. Swappable via
  `config :core, :scraper_client` (real vs mock). Auth: same HMAC scheme
  as the vision service (`X-Internal-Token`, secret
  `SCRAPER_HMAC_SECRET`).

  Two fuses are consulted before every request, covering different
  domains: `:scraper_fuse` (the sidecar itself — shared, service-wide) and
  the per-store fuse from `CircuitBreakers.store_fuse/1` (one hostile or
  broken shop must not stop scraping for the rest). Either open →
  `{:error, :circuit_open}`.
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
      |> Finch.request(Stacks.Finch, receive_timeout: 600_000, request_timeout: 600_000)
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

    with :ok <- ask(@fuse_name),
         :ok <- ask(store_fuse) do
      make_scraper_request(isbn, store_name, store_fuse, product_path)
    end
  end

  defp ask(fuse_name) do
    case :fuse.ask(fuse_name, :sync) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      :blown -> {:error, :circuit_open}
    end
  end

  # proto-enum-coverage: ScrapeOutcome ignore
  #   SCRAPE_OUTCOME_PRICED, SCRAPE_OUTCOME_NOT_STOCKED, SCRAPE_OUTCOME_ROBOTS_BLOCKED,
  #   SCRAPE_OUTCOME_INDEX_REQUIRED, SCRAPE_OUTCOME_RATE_LIMITED
  #   — this clause answers one question, "does this outcome melt the per-store
  #   fuse?", and for all five the answer is no. Melting on any of them is the exact
  #   trap ROBOTS_BLOCKED and RATE_LIMITED were split out of EXTRACTOR_FAILED to
  #   avoid: they recur on every attempt, so they would hold the fuse open forever.
  #   A new ScrapeOutcome must be added here or to this list deliberately.
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
          if_none_match: Keyword.get(validators, :etag) || "",
          if_modified_since: Keyword.get(validators, :last_modified) || ""
        })
      )
      |> Finch.request(Stacks.Finch, receive_timeout: 30_000, request_timeout: 30_000)
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
      |> Finch.request(Stacks.Finch, receive_timeout: 120_000, request_timeout: 120_000)
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

      {:ok, %{"outcome" => "FETCH_OUTCOME_RATE_LIMITED"} = ok} ->
        retry_after = Map.get(ok, "retry_after_seconds", 60)

        Logger.info(
          "ScraperClient: #{store} asked us to back off for #{retry_after}s; not retrying until then"
        )

        {:error, {:rate_limited, retry_after}}

      {:ok, %{"outcome" => "FETCH_OUTCOME_NOT_MODIFIED"} = ok} ->
        {:ok,
         %{
           status: 304,
           not_modified: true,
           etag: Map.get(ok, "etag", ""),
           last_modified: Map.get(ok, "last_modified", "")
         }}

      {:ok, %{"outcome" => "FETCH_OUTCOME_FETCHED", "status" => status, "body" => page} = ok} ->
        {:ok,
         %{
           status: status,
           body: page,
           sitemaps: Map.get(ok, "sitemaps", []),
           etag: Map.get(ok, "etag", ""),
           last_modified: Map.get(ok, "last_modified", "")
         }}

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

  defp do_build_index(store_name) do
    with :ok <- ask(@fuse_name) do
      index_request(store_name)
      |> Finch.request(Stacks.Finch, receive_timeout: 600_000, request_timeout: 600_000)
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
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:stacks, :scraper, :request, :start],
      %{system_time: System.system_time()},
      %{isbn: isbn, store: store_name}
    )

    case Finch.request(req, Stacks.Finch, receive_timeout: 30_000, request_timeout: 30_000) do
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
