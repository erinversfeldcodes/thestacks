import Config

# ── Test env: config/test.exs is self-contained, no env vars needed ──────────
if config_env() == :test do
  # Nothing here — tests use hardcoded values and mock backends from config/test.exs.
  # This early return prevents .env vars from overriding test configuration.
else
  # ── Secrets (required in dev + prod) ───────────────────────────────────────

  cloak_key =
    System.get_env("CLOAK_KEY") ||
      raise "environment variable CLOAK_KEY is missing. Generate with: :crypto.strong_rand_bytes(32) |> Base.encode64()"

  config :core, Stacks.Vault,
    ciphers: [
      default: {
        Cloak.Ciphers.AES.GCM,
        tag: "AES.GCM.V1", key: Base.decode64!(cloak_key), iv_length: 12
      }
    ]

  vision_hmac_secret =
    System.get_env("VISION_HMAC_SECRET") ||
      raise "environment variable VISION_HMAC_SECRET is missing."

  if byte_size(String.trim(vision_hmac_secret)) < 16 do
    raise "VISION_HMAC_SECRET must be at least 16 characters."
  end

  config :core, :vision_hmac_secret, vision_hmac_secret

  if guardian_secret = System.get_env("GUARDIAN_SECRET_KEY") do
    config :core, Stacks.Accounts.Guardian, issuer: "stacks", secret_key: guardian_secret
  end

  # ── Optional service config (dev + prod) ─────────────────────────────────

  if google_books_key = System.get_env("GOOGLE_BOOKS_API_KEY") do
    config :core, :google_books_api_key, google_books_key
  end

  if brave_key = System.get_env("BRAVE_SEARCH_API_KEY") do
    config :core, :brave_search_api_key, brave_key
  end

  if together_key = System.get_env("VISION_TOGETHER_API_KEY") do
    config :core, :vision_together_api_key, together_key
  end

  if auth_limit = System.get_env("RATE_LIMIT_AUTH") do
    config :core, :rate_limit_auth, String.to_integer(auth_limit)
  end

  if r2_account_id = System.get_env("R2_ACCOUNT_ID") do
    config :core, :storage, Stacks.Storage.R2

    config :ex_aws,
      access_key_id: System.fetch_env!("R2_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("R2_SECRET_ACCESS_KEY"),
      region: "auto"

    config :ex_aws, :s3,
      scheme: "https://",
      host: "#{r2_account_id}.r2.cloudflarestorage.com",
      region: "auto"

    config :core, :r2_bucket, System.get_env("R2_BUCKET_NAME", "stacks-images")
  end

  if scraper_hmac = System.get_env("SCRAPER_HMAC_SECRET") do
    config :core, :scraper_hmac_secret, scraper_hmac
  end

  if scraper_url = System.get_env("SCRAPER_SERVICE_URL") do
    config :core, :scraper_service_url, scraper_url
  end

  if searxng_url = System.get_env("SEARXNG_URL") do
    config :core, :searxng_url, searxng_url
  end

  # Enable the circuit breaker smoke endpoint on preview/dev deployments.
  # Never set SMOKE_TESTS_ENABLED in production — the endpoint blows all fuses
  # and waits 30s for probe-driven recovery. Default: false.
  if System.get_env("SMOKE_TESTS_ENABLED") in ~w(true 1) do
    config :core, :smoke_tests_enabled, true
  end

  # METRICS_SCRAPE_TOKEN guards /internal/metrics. StacksWeb.Plugs.MetricsAuth
  # is bearer-only (no IP allowlist) — every caller must present a matching
  # `Authorization: Bearer <token>` header. Unset = no one can scrape, not
  # even the SLO gate. Required in prod; CI sets it via `fly secrets`.
  config :core, :metrics_scrape_token, System.get_env("METRICS_SCRAPE_TOKEN")
end

# ── Prod-only (release) ───────────────────────────────────────────────────────
if config_env() == :prod do
  vision_service_url =
    System.get_env("VISION_SERVICE_URL") ||
      raise "environment variable VISION_SERVICE_URL is missing."

  config :core, :vision_service_url, vision_service_url

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :core, Core.Repo,
    url: database_url,
    ssl: true,
    parameters: [search_path: "public,op"],
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "thestacks.fly.dev"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :core, CoreWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  config :core, upload_dir: "/tmp/uploads"

  if System.get_env("EMAIL_PROVIDER") == "resend" do
    config :core, Stacks.Email.Mailer,
      adapter: Swoosh.Adapters.Resend,
      api_key: System.fetch_env!("RESEND_API_KEY")
  end

  # Erlang clustering on Fly.io — only active when FLY_APP_NAME is set.
  # rel/env.sh.eex sets RELEASE_DISTRIBUTION=name and RELEASE_NODE=<app>@<ipv6>.
  # Phoenix.PubSub's pg adapter broadcasts across all connected nodes automatically
  # once libcluster connects them, so SSE streams on any machine receive events
  # from Oban jobs on any other machine.
  if fly_app = System.get_env("FLY_APP_NAME") do
    config :libcluster,
      topologies: [
        fly: [
          strategy: Cluster.Strategy.DNSPoll,
          config: [
            polling_interval: 5_000,
            query: "#{fly_app}.internal",
            node_basename: fly_app
          ]
        ]
      ]
  end

  # Vision pipeline (Modal) can take 60–300s on cold starts. The SSE stream
  # must stay open long enough for the job to complete and broadcast its result.
  config :core, :sse_max_timeout_ms, 360_000
end
