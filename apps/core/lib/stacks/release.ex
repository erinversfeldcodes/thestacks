defmodule Stacks.Release do
  @moduledoc """
  Release tasks for production and preview deployments.

  Run via the compiled release binary:

      /app/bin/core eval 'Stacks.Release.migrate()'
      /app/bin/core eval 'Stacks.Release.seed()'
      /app/bin/core eval 'Stacks.Release.seed_prod()'

  Or via fly ssh console:

      fly ssh console --app <app> -C "/app/bin/core eval 'Stacks.Release.migrate()'"

  ## Seed gating

  `seed/0` is gated behind the `ALLOW_SEEDS` environment variable. Set
  `ALLOW_SEEDS=true` to enable seeding — this should only be done for dev
  and preview environments, never for production.

  `seed_prod/0` is the production-safe counterpart. It creates exactly one
  owner user from `PROD_OWNER_EMAIL` and `PROD_OWNER_PASSWORD` environment
  variables. It is idempotent (no-op if a user with that email already
  exists) and is NOT invoked by `seed/0` — the function's identity is the
  gate, not `ALLOW_SEEDS`.
  """

  @app :core

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def seed do
    if seeds_allowed?() do
      load_app()

      for repo <- repos() do
        {:ok, _, _} = Ecto.Migrator.with_repo(repo, fn _repo -> run_seeds() end)
      end
    else
      IO.puts("Seeds are disabled (ALLOW_SEEDS != \"true\"). Skipping.")
      :ok
    end
  end

  @doc """
  Creates exactly one owner user from `PROD_OWNER_EMAIL` and
  `PROD_OWNER_PASSWORD` environment variables.

  Idempotent: if a user with that email already exists, logs a message and
  returns `:ok` without modifying the existing user.

  Raises `RuntimeError` if either env var is missing/empty, or if user
  creation fails (e.g. password below minimum length). The exception surfaces
  through `release eval` with a non-zero exit code.

  This function is NOT called by `seed/0` — its identity is the gate. Invoke
  it directly via `/app/bin/core eval 'Stacks.Release.seed_prod()'`.
  """
  @spec seed_prod() :: :ok
  def seed_prod do
    email = fetch_required_env!("PROD_OWNER_EMAIL")
    password = fetch_required_env!("PROD_OWNER_PASSWORD")

    load_app()

    # We only need the primary repo (Core.Repo) for Accounts.register/1.
    # Use with_repo to start it so context calls work under release eval.
    [primary_repo | _] = repos()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(primary_repo, fn _repo ->
        do_seed_prod(email, password)
      end)

    :ok
  end

  defp do_seed_prod(email, password) do
    normalized_email = String.downcase(email)

    case Stacks.Accounts.get_user_by_email(normalized_email) do
      nil ->
        create_owner!(normalized_email, password)

      _existing ->
        IO.puts("seed_prod: owner already exists: #{normalized_email}")
        IO.puts("seed_prod: skipped (owner exists): #{normalized_email}")
        :ok
    end
  end

  defp create_owner!(email, password) do
    attrs = %{
      "email" => email,
      "password" => password,
      "role" => "owner",
      "display_name" => "Platform Owner"
    }

    case Stacks.Accounts.register(attrs) do
      {:ok, user} ->
        # Mark the owner email as confirmed so the login endpoint accepts
        # them immediately. The owner is created programmatically from a
        # trusted secret flow (PROD_OWNER_EMAIL/PASSWORD) — no email
        # verification posture applies. Without this, the login probe
        # (and the operator themselves) get `email_unconfirmed` on first
        # authentication attempt.
        confirm_owner!(user)
        IO.puts("seed_prod: created owner: #{email}")
        :ok

      {:error, %Ecto.Changeset{} = changeset} ->
        raise "seed_prod: failed to create owner: #{format_changeset_errors(changeset)}"

      {:error, reason} ->
        raise "seed_prod: failed to create owner: #{inspect(reason)}"
    end
  end

  defp confirm_owner!(user) do
    case Stacks.Accounts.mark_confirmed(user) do
      {:ok, confirmed} ->
        confirmed

      {:error, changeset} ->
        raise "seed_prod: failed to confirm owner: #{format_changeset_errors(changeset)}"
    end
  end

  defp format_changeset_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join(", ", fn {field, errors} -> "#{field}: #{Enum.join(errors, "; ")}" end)
  end

  defp fetch_required_env!(var) do
    case System.get_env(var) do
      nil -> raise "seed_prod: required environment variable #{var} is not set"
      "" -> raise "seed_prod: required environment variable #{var} is empty"
      value -> value
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

  defp seeds_allowed?, do: System.get_env("ALLOW_SEEDS") == "true"

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app, do: Application.load(@app)
end
