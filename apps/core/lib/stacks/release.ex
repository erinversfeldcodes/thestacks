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
  Runs the registered data corrections (`Stacks.DataCorrection.Registry`)
  against the connected database.

  **Dry-run by default** — it prints what each correction would change and
  writes nothing. Pass `apply: true` to write:

      /app/bin/core eval 'Stacks.Release.correct_data()'
      /app/bin/core eval 'Stacks.Release.correct_data(apply: true)'

  This is the release-side twin of `mix stacks.data.correct`, which a deployed
  image has no `mix` to run. `scripts/deploy-stack.sh` invokes it with
  `apply: true` immediately before migrating, because a correction is only
  useful ahead of the constraint that would otherwise reject the row (Issue
  #339: `book_editions_isbn_ean13_checksum`'s VALIDATE aborted a deploy).

  Raises on failure so `set -e` in the deploy script aborts while the old image
  is still serving traffic. Every applied change is audited in the same
  transaction as the change itself.

  Starts `Core.Repo` only — not every repo in `:ecto_repos` the way `migrate/0`
  does. Corrections are written against the application database; running them
  once per repo would repeat the work and then fail on the Oban repo's turn,
  where `Core.Repo` is no longer started.
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
  Operator-run GDPR right-to-erasure for ONE user, addressed strictly by
  `user_id`. Invoked from the `gdpr-erase-user` GitHub Actions workflow via:

      bin/core rpc 'Stacks.Release.gdpr_erase_user("<base64-json>")'

  The single argument is `Base64(JSON)` so the workflow carries arbitrary
  reason text into the rpc expression with NO shell/Elixir injection surface —
  the Base64 alphabet cannot break out of the string literal. Decoded JSON keys:

    * `"user_id"` (required) — the UUID of the user to erase. This is the ONLY
      globally-unique identifier; the destructive path refuses anything else so
      it can never resolve ambiguously to the wrong person. Resolve an email or
      handle to a `user_id` first with `gdpr_lookup_user/1` (the lookup workflow).
    * `"reason"` (required to execute) — operator justification, recorded
      encrypted in the `user.data_deleted` audit row. Must NOT contain the
      subject's personal data.
    * `"execute"` — `true` to actually erase; anything else is a dry run.
    * `"confirm"` (required to execute) — must equal `"user_id"` verbatim.

  A dry run (the default) prints the per-target counts that WOULD be erased,
  mutating nothing. Runs inside the live node (`rpc`), so it uses the
  already-started `Core.Repo`.

  Prints machine-parseable `GDPR_ERASE_*` markers and RAISES on any failure so
  the invoking `fly ssh` command exits non-zero. The erasure scrubs the
  operational + event-log data immediately; the analytics warehouse drops it on
  the next daily `DbtRefreshJob` full run (config.exs crontab, ≤24h).
  """
  @spec gdpr_erase_user(binary()) :: :ok
  def gdpr_erase_user(params_b64) when is_binary(params_b64) do
    params = params_b64 |> Base.decode64!() |> Jason.decode!()
    user_id = params |> Map.get("user_id", "") |> to_string() |> String.trim()
    reason = params |> Map.get("reason", "") |> to_string() |> String.trim()
    confirm = params |> Map.get("confirm", "") |> to_string() |> String.trim()
    execute? = Map.get(params, "execute") == true

    if user_id == "", do: erase_fail!("user_id is required")

    # Refuse anything that is not a UUID — no email/handle resolution lives in
    # the destructive path, so it can never delete the wrong user on an
    # ambiguous key. Use gdpr_lookup_user/1 to turn an email into a user_id.
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
  Read-only lookup that resolves an email or handle to its `user_id`(s) —
  the non-destructive companion to `gdpr_erase_user/1`, driven by the
  `gdpr-lookup-user` workflow:

      bin/core rpc 'Stacks.Release.gdpr_lookup_user("<base64-json>")'

  Decoded JSON: `%{"query" => email-or-handle}`. An email (`@`) is matched
  case-insensitively and MAY return several rows (email is not a unique key);
  a handle is unique and returns at most one. Prints one
  `GDPR_LOOKUP_MATCH user_id=<uuid> email=<email> handle=<handle>` per match and
  a trailing `GDPR_LOOKUP_COUNT <n>`, so the operator can pick the right
  `user_id` to feed the erase workflow. Never mutates anything.
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
