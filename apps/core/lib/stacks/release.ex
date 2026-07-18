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

  alias Ecto.Adapters.SQL
  alias Stacks.Accounts
  alias Stacks.GDPR.Deletion

  @app :core

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Prints the migration versions applied on the connected DB, one per line,
  prefixed with `APPLIED_VERSION `.

  Consumed by `scripts/deploy-stack.sh`'s migration-integrity guard: the deploy
  compares these against the migration files present in the repo and FAILS if
  the repo contains a migration that is not applied on the deployed DB. This
  catches the silent failure where `migrate/0` reports "already up" but a
  migration never reached the image (e.g. an uncommitted/untracked migration
  file absent from the working tree at image-build time) → the deployed schema
  ends up behind the code → fail-closed auth/DB outages.
  """
  def print_applied_versions do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &emit_applied_versions/1)
    end
  end

  # Read schema_migrations directly rather than via
  # Ecto.Migrator.migrated_versions/1: the guard needs an exact, unambiguous
  # list of every recorded version, and the direct query matches what a plain
  # `SELECT` sees.
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
  Seed the dev/preview fixtures INSIDE the already-running release node.

  Invoke via `bin/core rpc 'Stacks.Release.seed_live()'` (NOT `eval`). Unlike
  `seed/0` — which is written for the fresh-BEAM `eval` path and therefore
  `load_app`s and `with_repo`-starts each repo — this assumes the app and its
  repos are already started (they are, in the serving node), so it evaluates the
  seeds directly against the live `Core.Repo`.

  Why: `eval 'seed()'` spawns a SECOND BEAM alongside the serving Phoenix, and on
  the 512 MB preview VM that second BEAM plus the ~160-book in-memory seed set
  OOMs the machine (the exec drops with a bare `EOF`). Running the seed in the
  existing node via `rpc` avoids the second BEAM entirely.

  No `ALLOW_SEEDS` gate: `rpc` cannot inject env into the running node, and — like
  `seed_prod/0` and `seed_prober/0` — the function's identity is the gate.
  `scripts/deploy-stack.sh` calls this ONLY in its preview branch, never prod.
  """
  @spec seed_live() :: term()
  def seed_live do
    run_seeds()
  end

  @doc """
  Operator-run GDPR right-to-erasure for one user, resolved by email or handle.
  Invoked from the `gdpr-erase-user` GitHub Actions workflow via:

      bin/core rpc 'Stacks.Release.gdpr_erase_user("<base64-json>")'

  The single argument is `Base64(JSON)` so the workflow can carry arbitrary
  identifier/reason text into the rpc expression with NO shell/Elixir injection
  surface — the Base64 alphabet cannot break out of the string literal. Decoded
  JSON keys:

    * `"identifier"` (required) — email (contains `@`) or handle.
    * `"reason"` (required to execute) — operator justification, recorded
      encrypted in the `user.data_deleted` audit row. Must NOT contain the
      subject's personal data.
    * `"execute"` — `true` to actually erase; anything else is a dry run.
    * `"confirm"` (required to execute) — must equal `"identifier"` verbatim.

  A dry run (the default) resolves the user and prints the per-target counts
  that WOULD be erased, mutating nothing. Runs inside the live node (`rpc`), so
  it uses the already-started `Core.Repo`.

  Prints machine-parseable `GDPR_ERASE_*` markers and RAISES on any failure so
  the invoking `fly ssh` command exits non-zero. The erasure itself scrubs the
  operational + event-log data immediately; the analytics warehouse drops it on
  the next daily `DbtRefreshJob` full run (config.exs crontab, ≤24h).
  """
  @spec gdpr_erase_user(binary()) :: :ok
  def gdpr_erase_user(params_b64) when is_binary(params_b64) do
    params = params_b64 |> Base.decode64!() |> Jason.decode!()
    identifier = params |> Map.get("identifier", "") |> to_string() |> String.trim()
    reason = params |> Map.get("reason", "") |> to_string() |> String.trim()
    confirm = params |> Map.get("confirm", "") |> to_string() |> String.trim()
    execute? = Map.get(params, "execute") == true

    if identifier == "", do: erase_fail!("identifier is required")

    user = resolve_erase_user(identifier)
    if is_nil(user), do: erase_fail!("no user found for identifier #{inspect(identifier)}")

    IO.puts("GDPR_ERASE_RESOLVED user_id=#{user.id}")

    {:ok, counts} = Deletion.preview_user_data(user.id)
    IO.puts("GDPR_ERASE_PREVIEW #{Jason.encode!(counts)}")

    cond do
      not execute? ->
        IO.puts("GDPR_ERASE_RESULT dry_run — nothing deleted")
        :ok

      reason == "" ->
        erase_fail!("reason is required to execute an erasure")

      confirm != identifier ->
        erase_fail!("confirmation does not match identifier — refusing to erase")

      true ->
        do_erase(user.id, reason)
    end
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

  defp resolve_erase_user(identifier) do
    if String.contains?(identifier, "@") do
      Accounts.get_user_by_email(identifier)
    else
      Accounts.get_user_by_handle(identifier)
    end
  end

  defp erase_fail!(message) do
    IO.puts("GDPR_ERASE_ERROR #{message}")
    raise "GDPR erase aborted: #{message}"
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

  @doc """
  Creates exactly one probe user from `STACKS_PROBER_EMAIL` and
  `STACKS_PROBER_PASSWORD` environment variables.

  The prober user has role `"user"` (NOT `"owner"`) so probe credentials
  never carry owner privileges. Idempotent: if a user with that email
  already exists, logs a message and returns `:ok` without modifying the
  existing user.

  Raises `RuntimeError` if either env var is missing/empty, or if user
  creation fails.
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

    # Use the registration changeset directly (not Accounts.register) to
    # bypass maybe_assign_owner_role, which forces role="owner" on empty DBs.
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
