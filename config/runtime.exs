import Config

# Load secrets from env vars for dev and prod.
# Tests use hardcoded values from config/test.exs — no env vars required.
if config_env() != :test do
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
end

if config_env() == :prod do
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
    parameters: [search_path: "op,public"],
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
end
