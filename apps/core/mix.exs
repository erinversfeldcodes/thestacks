defmodule Core.MixProject do
  use Mix.Project

  def project do
    [
      app: :core,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      test_coverage: [tool: ExCoveralls, minimum_coverage: 80],
      dialyzer: [ignore_warnings: ".dialyzer_ignore.exs"]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      mod: {Core.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7.22"},
      {:phoenix_ecto, "~> 4.6"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:guardian, "~> 2.3"},
      {:guardian_db, "~> 3.0"},
      {:argon2_elixir, "~> 4.1"},
      {:oban, "~> 2.18"},
      {:fuse, "~> 2.5"},
      {:cloak_ecto, "~> 1.3"},
      {:jason, "~> 1.4"},
      {:plug_cowboy, "~> 2.8"},
      {:cors_plug, "~> 3.0"},
      {:prom_ex, "~> 1.9"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},

      # Dev/Test
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:finch, "~> 0.19"},
      {:broadway, "~> 1.1"},
      {:elixir_feed_parser, "~> 2.1"},
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:ex_machina, "~> 2.8", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:timex, "~> 3.7"},
      # Canonical Elixir time-zone database (bundled IANA data, no runtime
      # fetch). tzdata remains in the lockfile as timex's hard dependency but
      # is inert: its autoupdater is disabled in config.exs.
      {:time_zone_info, "~> 0.7"},
      # Override tzdata's `hackney ~> 1.17` pin. hackney 1.x carries four
      # security advisories (GHSA-gp9c-pm5m-5cxr and friends), all patched in
      # 4.0.1+. Nothing calls hackney at runtime: swoosh uses Req, ex_aws is
      # configured with ExAws.Request.Req, and tzdata's autoupdate (its only
      # hackney call site) is disabled.
      {:hackney, "~> 4.0", override: true},
      {:nimble_csv, "~> 1.2"},
      {:nimble_pool, "~> 1.1"},
      {:libcluster, "~> 3.3"},
      {:nimble_totp, "~> 1.0"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run apps/core/priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["cmd --cd assets npm install"],
      "assets.build": ["cmd --cd assets node build.js"],
      "assets.deploy": ["cmd --cd assets npm run deploy", "phx.digest"]
    ]
  end
end
