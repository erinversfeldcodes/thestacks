import Config

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
  raise "VISION_HMAC_SECRET must be at least 16 characters. Got an empty or too-short value."
end

config :core, :vision_hmac_secret, vision_hmac_secret

if auth_limit = System.get_env("RATE_LIMIT_AUTH") do
  config :core, :rate_limit_auth, String.to_integer(auth_limit)
end

if config_env() == :prod do
  vision_service_url =
    System.get_env("VISION_SERVICE_URL") ||
      raise "environment variable VISION_SERVICE_URL is missing."

  config :core, :vision_service_url, vision_service_url

  searxng_url =
    System.get_env("SEARXNG_URL") || "http://thestacks-searxng.internal:8080"

  config :core, :searxng_url, searxng_url

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :core, Core.Repo,
    url: database_url,
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

  # Use an absolute writable path for uploads in production.
  # The relative default ("priv/static/uploads") is not writable in a Fly.io release.
  config :core, upload_dir: "/tmp/uploads"

  if System.get_env("EMAIL_PROVIDER") == "resend" do
    config :core, Stacks.Email.Mailer,
      adapter: Swoosh.Adapters.Resend,
      api_key: System.fetch_env!("RESEND_API_KEY")
  end
end
