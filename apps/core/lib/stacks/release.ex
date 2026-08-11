defmodule Stacks.Release do
  @moduledoc """
    Release tasks, run via the compiled binary:

        /app/bin/core eval 'Stacks.Release.migrate'
        /app/bin/core rpc  'Stacks.Release.seed_live'

    `seed/0` is gated behind `ALLOW_SEEDS=true`; `seed_live/0` is prod-guarded by
    `STACKS_E2E_TEST_HELPERS`. Prefer `rpc` on the 512MB preview VM — `eval`
    spawns a second BEAM and OOMs it.
  """

  alias Core.Repo
  alias Ecto.Adapters.SQL
  alias Stacks.Accounts
  alias Stacks.Accounts.User
  alias Stacks.GDPR.Deletion

  @app :core

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
    The deploy entry point (`release_command` in fly.core.toml): corrections,
    migrate, corrections again. Order matters — a migration adding a constraint
    is a claim about existing data, so repairs run before it; the second sweep
    covers corrections whose target column the migration just added.
  """
  @spec deploy() :: :ok
  def deploy do
    correct_data(apply: true)

    migrate()

    correct_data(apply: true)

    :ok
  end

  @doc """
    Runs the registered data corrections. Dry-run by default (prints, writes
    nothing); pass `apply: true` to write. Release-side twin of
    `mix stacks.data.correct`.
  """
  @spec correct_data(keyword()) :: :ok
  def correct_data(opts \\ []) do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Repo, fn _repo ->
        run_corrections(Keyword.get(opts, :apply, false))
      end)

    :ok
  end

  defp run_corrections(apply?) do
    case Stacks.DataCorrection.run_all(Stacks.DataCorrection.Registry.all(),
           apply: apply?,
           invoked_by: "Stacks.Release.correct_data"
         ) do
      {:ok, outcomes} ->
        Enum.each(outcomes, &IO.puts(&1.report))

      {:error, {correction, reason}} ->
        raise "data correction #{inspect(correction)} failed: #{inspect(reason)} — nothing was committed"
    end
  end

  @doc """
    Prints applied migration versions (`APPLIED_VERSION <v>` lines) for
    deploy-stack.sh's integrity guard, which fails the deploy if the repo holds
    a migration the DB never ran — catching a false "already up".
  """
  def print_applied_versions do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &emit_applied_versions/1)
    end
  end

  defp emit_applied_versions(started_repo) do
    %{rows: rows} = SQL.query!(started_repo, "SELECT version FROM schema_migrations", [])
    Enum.each(rows, fn [version] -> IO.puts("APPLIED_VERSION #{version}") end)
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
    Seeds dev/preview fixtures INSIDE the running node — invoke via
    `bin/core rpc`, never `eval` (a second BEAM OOMs the 512MB preview VM).
    Prod-guarded by `STACKS_E2E_TEST_HELPERS`; assumes app + repos already
    started.
  """
  @spec seed_live() :: term()
  def seed_live do
    run_seeds()
  end

  @doc """
    Operator-run GDPR erasure for ONE user, by `user_id` only, driven by the
    `gdpr-erase-user` workflow. The argument is Base64(JSON) so arbitrary reason
    text crosses the rpc boundary with no shell/Elixir injection surface.
    Decoded: `%{"user_id" =>, "reason" =>, "actor" =>, "dry_run" =>}`.
  """
  @spec gdpr_erase_user(binary()) :: :ok
  def gdpr_erase_user(params_b64) when is_binary(params_b64) do
    params = params_b64 |> Base.decode64!() |> Jason.decode!()
    user_id = params |> Map.get("user_id", "") |> to_string() |> String.trim()
    reason = params |> Map.get("reason", "") |> to_string() |> String.trim()
    confirm = params |> Map.get("confirm", "") |> to_string() |> String.trim()
    execute? = Map.get(params, "execute") == true

    if user_id == "", do: erase_fail!("user_id is required")

    case Ecto.UUID.cast(user_id) do
      :error ->
        erase_fail!(
          "user_id #{inspect(user_id)} is not a valid UUID — resolve it via the lookup workflow"
        )

      {:ok, _} ->
        :ok
    end

    if is_nil(Repo.get(User, user_id)),
      do: erase_fail!("no user exists with user_id #{inspect(user_id)}")

    IO.puts("GDPR_ERASE_RESOLVED user_id=#{user_id}")

    {:ok, counts} = Deletion.preview_user_data(user_id)
    IO.puts("GDPR_ERASE_PREVIEW #{Jason.encode!(counts)}")

    cond do
      not execute? ->
        IO.puts("GDPR_ERASE_RESULT dry_run — nothing deleted")
        :ok

      reason == "" ->
        erase_fail!("reason is required to execute an erasure")

      confirm != user_id ->
        erase_fail!("confirmation does not match user_id — refusing to erase")

      true ->
        do_erase(user_id, reason)
    end
  end

  @doc """
    Read-only companion to `gdpr_erase_user/1` (the `gdpr-lookup-user`
    workflow): resolves Base64(JSON) `%{"query" => email-or-handle}` to
    user_id rows. Emails match case-insensitively and may return several rows;
    handles are unique.
  """
  @spec gdpr_lookup_user(binary()) :: :ok
  def gdpr_lookup_user(params_b64) when is_binary(params_b64) do
    params = params_b64 |> Base.decode64!() |> Jason.decode!()
    query = params |> Map.get("query", "") |> to_string() |> String.trim()

    if query == "" do
      IO.puts("GDPR_LOOKUP_ERROR query is required")
      raise "GDPR lookup aborted: query is required"
    end

    matches =
      if String.contains?(query, "@") do
        Accounts.find_users_by_email(query)
      else
        case Accounts.get_user_by_handle(query) do
          nil -> []
          user -> [user]
        end
      end

    Enum.each(matches, fn u ->
      IO.puts("GDPR_LOOKUP_MATCH user_id=#{u.id} email=#{u.email} handle=#{u.handle}")
    end)

    IO.puts("GDPR_LOOKUP_COUNT #{length(matches)}")
    :ok
  end

  defp do_erase(user_id, reason) do
    case Deletion.delete_user_data(user_id, reason: reason, actor: "gh-actions") do
      {:ok, result} ->
        summary =
          result
          |> Map.take([
            :delete_history,
            :delete_placements,
            :delete_bookshelves,
            :erase_comments,
            :scrub_event_log,
            :revoke_sessions
          ])
          |> Jason.encode!()

        IO.puts("GDPR_ERASE_RESULT deleted #{summary}")
        :ok

      {:error, step, reason, _changes} ->
        erase_fail!("erasure transaction failed at #{step}: #{inspect(reason)}")
    end
  end

  defp erase_fail!(message) do
    IO.puts("GDPR_ERASE_ERROR #{message}")
    raise "GDPR erase aborted: #{message}"
  end

  @doc """
    Creates exactly one owner user from `PROD_OWNER_EMAIL`/`PROD_OWNER_PASSWORD`.
    Idempotent (existing email → log + `:ok`). Raises on missing env or invalid
    attrs so `release eval` exits non-zero and the deploy fails loudly.
  """
  @spec seed_prod() :: :ok
  def seed_prod do
    email = fetch_required_env!("PROD_OWNER_EMAIL")
    password = fetch_required_env!("PROD_OWNER_PASSWORD")

    load_app()

    [primary_repo | _] = repos()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(primary_repo, fn _repo ->
        do_seed_prod(email, password)
      end)

    :ok
  end

  @doc """
    Creates exactly one probe user from `STACKS_PROBER_EMAIL`/`_PASSWORD` with
    role `"user"` — probe credentials never carry owner privileges. Idempotent;
    raises on missing env or failed creation.
  """
  @spec seed_prober() :: :ok
  def seed_prober do
    email = fetch_required_env!("STACKS_PROBER_EMAIL")
    password = fetch_required_env!("STACKS_PROBER_PASSWORD")

    load_app()

    [primary_repo | _] = repos()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(primary_repo, fn _repo ->
        do_seed_prober(email, password)
      end)

    :ok
  end

  defp do_seed_prober(email, password) do
    normalized_email = String.downcase(email)

    case Stacks.Accounts.get_user_by_email(normalized_email) do
      nil ->
        create_prober!(normalized_email, password)

      _existing ->
        IO.puts("seed_prober: prober already exists: #{normalized_email}")
        :ok
    end
  end

  defp create_prober!(email, password) do
    attrs = %{
      "email" => email,
      "password" => password,
      "role" => "user",
      "display_name" => "Platform Prober"
    }

    changeset =
      Stacks.Accounts.registration_changeset(%Stacks.Accounts.User{}, attrs)

    case Core.Repo.insert(changeset) do
      {:ok, user} ->
        confirm_prober!(user)
        IO.puts("seed_prober: created prober: #{email}")
        :ok

      {:error, %Ecto.Changeset{} = cs} ->
        raise "seed_prober: failed to create prober: #{format_changeset_errors(cs)}"
    end
  end

  defp confirm_prober!(user) do
    case Stacks.Accounts.mark_confirmed(user) do
      {:ok, confirmed} ->
        confirmed

      {:error, changeset} ->
        raise "seed_prober: failed to confirm prober: #{format_changeset_errors(changeset)}"
    end
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
        confirm_owner!(user)
        IO.puts("seed_prod: created owner: #{email}")
        :ok

      {:error, %Ecto.Changeset{} = changeset} ->
        raise "seed_prod: failed to create owner: #{format_changeset_errors(changeset)}"
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
      nil -> raise "required environment variable #{var} is not set"
      "" -> raise "required environment variable #{var} is empty"
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
