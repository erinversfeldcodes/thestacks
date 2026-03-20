defmodule Stacks.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      dialyzer: [plt_add_apps: [:mix]],
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  defp deps do
    []
  end

  defp aliases do
    [
      setup: ["deps.get", "cmd --app core --cd assets npm install", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.deploy": ["cmd --app core mix assets.deploy"]
    ]
  end

  defp releases do
    [
      core: [
        applications: [core: :permanent],
        include_executables_for: [:unix],
        strip_beams: true
      ]
    ]
  end
end
