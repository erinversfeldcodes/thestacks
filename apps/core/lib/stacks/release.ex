defmodule Stacks.Release do
  @moduledoc """
  Release tasks for production and preview deployments.

  Run via the compiled release binary:

      /app/bin/core eval 'Stacks.Release.migrate()'
      /app/bin/core eval 'Stacks.Release.seed()'

  Or via fly ssh console:

      fly ssh console --app <app> -C "/app/bin/core eval 'Stacks.Release.migrate()'"
  """

  @app :core

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def seed do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, fn _repo -> run_seeds() end)
    end
  end

  defp run_seeds do
    seeds_file = Application.app_dir(@app, "priv/repo/seeds.exs")

    if File.exists?(seeds_file) do
      Code.eval_file(seeds_file)
    else
      IO.puts("Seeds file not found at #{seeds_file}, skipping.")
    end
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app, do: Application.load(@app)
end
