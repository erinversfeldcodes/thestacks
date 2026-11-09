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
  alias Stacks.Audit
  alias Stacks.Costs.PlatformCost
  alias Stacks.GDPR.Deletion
  alias Stacks.Workers.AuditRetentionJob
  alias Stacks.Workers.DiscoverBookstoreEventsJob
  alias Stacks.Workers.ExpiredEmailChangesJob
  alias Stacks.Workers.ExpiredInvitesSweepJob
  alias Stacks.Workers.ExpiredUnverifiedAccountsJob
  alias Stacks.Workers.ExportRetentionJob
  alias Stacks.Workers.GuardianTokenSweepJob
  alias Stacks.Workers.ImageRetentionJob
  alias Stacks.Workers.LibraryImportRowRetentionJob
  alias Stacks.Workers.LlmCallLogRetentionJob
  alias Stacks.Workers.RefreshCostsJob
  alias StacksWeb.Plugs.E2ETestHelper

  @app :core

  # Connection options every release task must start its repo with: the OWNER
  # connection, taken from `DATABASE_URL`.
  #
  # ⚠️ This exists because the runtime pools no longer necessarily use that
  # role. `config/runtime.exs` points `Core.Repo` and `Core.ObanRepo` at
  # `APP_DATABASE_URL` when it is set — the least-privilege `stacks_app` role
  # — falling back to `DATABASE_URL` when it is not. Every task in this module
  # does something a least-privilege role cannot: `migrate/0` runs DDL, which
  # requires ownership; `print_applied_versions/0` and `correct_data/1` run
  # inside the deploy as operator actions.
  #
  # So a release task must not inherit the repo's configured URL. Without this
  # override, setting `APP_DATABASE_URL` would make the next deploy's
  # migration step fail on `permission denied` — the change would look inert
  # right up to the moment it took the stack down, which is the worst shape a
  # flag can have.
  #
  # Empty when `DATABASE_URL` is unset, so dev and test — where the repo's own
  # config is already correct and there is no second role — are untouched.
  #
  # ⛔ **These options are NOT enough on their own, and believing they were
  # took a preview deploy down.** `Ecto.Migrator.with_repo/3` reads only
  # `:mode` and `:pool_size` from the options it is given — it starts the repo
  # with `repo.start_link(pool_size: pool_size)` and discards everything else,
  # `:url` included (ecto_sql 3.14.0, `migrator.ex:817`). So passing these as
  # `with_repo`'s third argument had no effect whatsoever.
  #
  # That was invisible for as long as `APP_DATABASE_URL` was unset, because
  # then `config/runtime.exs` pointed the repo at `DATABASE_URL` anyway and the
  # override agreed with the config it was failing to override. The first
  # deploy that set the secret ran the release command as `stacks_app`, which
  # on a fresh preview branch does not even exist yet — the role is created by
  # a migration that this very command runs. `28P01`, twice, deploy aborted.
  #
  # ⚠️ So use `with_owner_repo/2` below, never `with_repo` plus these options.
  # The only thing that changes where the repo connects is the repo's own
  # CONFIG, which is why that function sets it.
  @spec owner_repo_opts() :: keyword()
  defp owner_repo_opts do
    case System.get_env("DATABASE_URL") do
      nil -> []
      "" -> []
      url -> [url: url]
    end
  end

  @doc """
      Runs `fun` with `repo` connected as the OWNER, whatever the runtime pools
      are configured to use.

      The owner URL is written into the repo's application config for the
      duration and restored afterwards, because `Ecto.Migrator.with_repo/3`
      honours only `:mode` and `:pool_size` from its options — config is the one
      channel that actually decides where the pool connects.

      ⚠️ Restores the previous config in an `after`, so a raising task cannot
      leave the repo pointed at the owner for whatever runs next in the same
      node. A release task is usually the only thing in its BEAM, but "usually"
      is not a reason to leak a credential-bearing config.

      A no-op pass-through when `DATABASE_URL` is unset: dev and test have one
      role and the repo's own config is already right.
  """
  @spec with_owner_repo(module(), (module() -> any())) :: {:ok, any(), [atom()]}
  def with_owner_repo(repo, fun) do
    with_owner_repo_config(repo, fn -> Ecto.Migrator.with_repo(repo, fun) end)
  end

  @doc """
      Runs `fun` with `repo`'s application config pointed at the owner URL, and
      restores the previous config afterwards.

      ⚠️ Separated from `with_owner_repo/2` so the config swap — the part that
      actually decides where a pool connects — can be asserted without starting
      a real pool. A test that had to connect could only verify this against a
      live database, which is how it went unverified in the first place.

      A no-op pass-through when `DATABASE_URL` is unset.

      ⛔ Raises when `repo` is already started AND the role split is active
      (`APP_DATABASE_URL` set to something other than the owner). A started
      repo holds its pool already, so the swap cannot move it — it would
      succeed and achieve nothing, which is the shape this defect returns in.
      With the split inactive a started pool is already the owner, so there is
      nothing to refuse and in-process callers are untouched.
  """
  @spec with_owner_repo_config(module(), (-> any())) :: any()
  def with_owner_repo_config(repo, fun) do
    case owner_repo_opts() do
      [] ->
        fun.()

      opts ->
        refuse_if_already_started!(repo)

        previous = Application.get_env(@app, repo, [])

        try do
          Application.put_env(@app, repo, Keyword.merge(previous, opts))
          fun.()
        after
          Application.put_env(@app, repo, previous)
        end
    end
  end

  # ⛔ A started repo already holds its pool, so changing config cannot move it.
  # Proceeding would run the task on whatever connection the pool was opened
  # with — the runtime role — and SUCCEED at the config swap while failing at
  # the only thing it is for. That silent no-op is the exact shape this defect
  # returns in: the override appears applied and has no effect.
  #
  # ⚠️ Two conditions, not one, and the second is what makes this safe to add.
  # A started repo is only a problem when its pool is on a DIFFERENT connection
  # than the owner — which is the case precisely when the role split is active,
  # because `config/runtime.exs` points the runtime pools at `APP_DATABASE_URL`
  # when it is set and at `DATABASE_URL` when it is not. With the split
  # inactive, a started pool is already the owner, so there is nothing the swap
  # needed to achieve and nothing to refuse.
  #
  # ⛔ Refusing on started-ness ALONE breaks six passing tests, which is how
  # this got narrowed: `seed_prod/0` and `seed_prober/0` are called in-process
  # by `release_test.exs` against the started test repo. "Release tasks run
  # before the app boots" is true of how they are INVOKED in a deploy — all six
  # callers of the wrapper go through `eval`, in their own BEAM — and false of
  # the suite that tests them. The broad guard would have been a block on a
  # correct caller, which is a worse defect than the silent no-op it prevents.
  #
  # ⚠️ The second condition is a proxy, stated as one. Which role a live pool
  # actually holds is not readable from config — it would take a `current_user`
  # query against that pool — so this asks whether the split is active instead,
  # using the same variable `runtime.exs` decides with. It is the right proxy
  # for the case that matters and it will not fire for a pool that is already
  # the owner by some route this does not model.
  #
  # ⚠️ Raising rather than falling back: a release task doing DDL as the
  # least-privilege role fails on `permission denied` somewhere further in, at a
  # point that does not name the cause. Better to stop here and say why.
  defp refuse_if_already_started!(repo) do
    if GenServer.whereis(repo) && runtime_pools_are_not_the_owner?() do
      raise """
      #{inspect(repo)} is already started, so pointing it at the owner connection is impossible: \
      its pool is open on the runtime role and a config change cannot move it.

      A release task needing the owner must run in its own BEAM — `bin/core eval` or \
      `fly machine exec` — not via `rpc` against a live node. Invoked from a running node it \
      would silently execute as the least-privilege role and fail later on `permission denied`, \
      somewhere that does not name this as the cause.
      """
    end

    :ok
  end

  defp runtime_pools_are_not_the_owner? do
    case System.get_env("APP_DATABASE_URL") do
      nil -> false
      "" -> false
      app_url -> app_url != System.get_env("DATABASE_URL")
    end
  end

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        with_owner_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
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
      with_owner_repo(Repo, fn _repo -> run_corrections(Keyword.get(opts, :apply, false)) end)

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
      {:ok, _, _} =
        with_owner_repo(repo, &emit_applied_versions/1)
    end
  end

  defp emit_applied_versions(started_repo) do
    %{rows: rows} = SQL.query!(started_repo, "SELECT version FROM schema_migrations", [])
    Enum.each(rows, fn [version] -> IO.puts("APPLIED_VERSION #{version}") end)
  end

  @doc """
      Prints one `CONNECTION_POSTURE` line per repo: the role each pool is
      actually connected as, and what that role may do.

      ⚠️ A NAMED function because the alternative is an ad-hoc expression piped
      through `fly ssh console -C "… rpc '…'"`, where the quoting has to survive
      a shell, an ssh command string, and Elixir — and it does not. Nine
      attempts at one such expression failed on quoting alone, which is time
      spent on syntax rather than on the question. Anything worth asking a
      deployed node twice belongs here, where the invocation is a bare call:

          fly ssh console -a <app> -C "/app/bin/core rpc 'Stacks.Release.print_connection_posture()'"

      ⚠️ Deliberately NOT wrapped in `with_owner_repo/2`. The question is what
      the RUNTIME pools are connected as; overriding them to the owner first
      would answer a question nobody asked and report the posture as correct
      whatever it is.

      ⛔ Prints no error text, only a classification. This function exists to be
      run against production, and an error stream is exactly where a credential
      resurfaces — a connection string quoted back inside a failure message is
      how one got into a transcript. The postgres code says what went wrong
      without quoting anything back.
  """
  @spec print_connection_posture() :: :ok
  def print_connection_posture do
    load_app()

    Enum.each(repos(), &emit_connection_posture/1)

    :ok
  end

  # The privileges the role split claims, asked of the catalogue rather than by
  # attempting them: a probe that INSERTs to find out whether it may INSERT has
  # to be undone, and a posture check must not write. `to_regclass` guards each
  # table lookup, because `has_table_privilege` raises on a table that does not
  # exist yet and a posture check must not fail for being run early.
  @posture_query """
  SELECT current_user,
         current_database(),
         has_schema_privilege('op', 'usage'),
         CASE WHEN to_regclass('op.users') IS NULL THEN NULL
              ELSE has_table_privilege('op.users', 'insert') END,
         has_schema_privilege('marts', 'usage'),
         CASE WHEN to_regclass('audit.audit_log') IS NULL THEN NULL
              ELSE has_table_privilege('audit.audit_log', 'insert') END,
         CASE WHEN to_regclass('audit.audit_log') IS NULL THEN NULL
              ELSE has_table_privilege('audit.audit_log', 'delete') END,
         CASE WHEN to_regclass('public.schema_migrations') IS NULL THEN NULL
              ELSE has_table_privilege('public.schema_migrations', 'update') END
  """

  defp emit_connection_posture(repo) do
    # `with_repo` runs the function directly when the repo is already started,
    # which is the `rpc` case, and starts it on its OWN config otherwise, which
    # is the `eval` case. Both report the runtime connection, which is the point.
    case Ecto.Migrator.with_repo(repo, &probe_posture(repo, &1)) do
      {:ok, :ok, _apps} -> :ok
      {:error, reason} -> emit_posture_error(repo, reason)
    end
  rescue
    error -> emit_posture_error(repo, error)
  end

  defp probe_posture(repo, started_repo) do
    %{rows: [row]} = SQL.query!(started_repo, @posture_query, [])

    [
      role,
      database,
      op_usage,
      op_write,
      marts_usage,
      audit_insert,
      audit_delete,
      migrations_write
    ] =
      row

    IO.puts(
      "CONNECTION_POSTURE repo=#{inspect(repo)} role=#{role} database=#{database} " <>
        "op_usage=#{posture_value(op_usage)} op_write=#{posture_value(op_write)} " <>
        "marts_usage=#{posture_value(marts_usage)} " <>
        "audit_insert=#{posture_value(audit_insert)} audit_delete=#{posture_value(audit_delete)} " <>
        "can_rewrite_migrations=#{posture_value(migrations_write)}"
    )

    :ok
  end

  # `unknown` rather than `false` for an absent table: a privilege that could
  # not be asked about is not a privilege denied, and reading one as the other
  # is how a posture check reports a correct stack as broken, or the reverse.
  defp posture_value(nil), do: "unknown"
  defp posture_value(value), do: to_string(value)

  defp emit_posture_error(repo, %Postgrex.Error{postgres: %{code: code}}) do
    IO.puts("CONNECTION_POSTURE_ERROR repo=#{inspect(repo)} kind=Postgrex.Error code=#{code}")
  end

  defp emit_posture_error(repo, error) when is_exception(error) do
    IO.puts("CONNECTION_POSTURE_ERROR repo=#{inspect(repo)} kind=#{inspect(error.__struct__)}")
  end

  defp emit_posture_error(repo, _reason) do
    IO.puts("CONNECTION_POSTURE_ERROR repo=#{inspect(repo)} kind=unknown")
  end

  def seed do
    if seeds_allowed?() do
      load_app()

      for repo <- repos() do
        {:ok, _, _} =
          with_owner_repo(repo, fn _repo -> run_seeds() end)
      end
    else
      IO.puts("Seeds are disabled (ALLOW_SEEDS != \"true\"). Skipping.")
      :ok
    end
  end

  @doc """
      Seeds dev/preview fixtures INSIDE the running node — invoke via
      `bin/core rpc`, never `eval` (a second BEAM OOMs the 512MB preview VM).
      Assumes app + repos already started.

      ⛔ **PROD-GUARDED BY `STACKS_E2E_TEST_HELPERS`, WHICH IT PREVIOUSLY ONLY
      CLAIMED TO BE.** This docstring said "Prod-guarded by
      `STACKS_E2E_TEST_HELPERS`" while the body called `run_seeds/0` directly,
      with no guard of any kind. Anyone able to reach `bin/core rpc` on a
      production machine could run the whole dev-fixture seed against the
      production database.

      ⚠️ The guard went missing in the `eval` → `rpc` change, and the reason is
      worth keeping: `seed/0` is gated on `ALLOW_SEEDS`, which is read inside the
      process the release task starts, and that gate cannot survive `rpc` —
      `rpc` runs in the ALREADY-RUNNING node, whose environment the operator
      cannot set per invocation. So the replacement had to be an env the node is
      deployed with, which `STACKS_E2E_TEST_HELPERS` is: `scripts/deploy-stack.sh`
      sets it on the preview branch only, and production never carries it.

      ⚖️ "It is only called from the preview branch of the deploy script" is not a
      guard. It is true today, it is invisible at the call site, and it is exactly
      the argument that let the missing gate look fine.
  """
  @spec seed_live() :: term()
  def seed_live do
    if E2ETestHelper.enabled?() do
      run_seeds()
    else
      raise "refusing to seed: STACKS_E2E_TEST_HELPERS is not \"1\", " <>
              "so this node is not a preview stack. Seeding here would write " <>
              "dev fixtures into whatever database this node is pointed at."
    end
  end

  @doc """
      Restores a platform operator's own access when session transport fails.

      ⛔ **MOVING THE SESSION FROM A BEARER TOKEN TO AN `HttpOnly` COOKIE CAN LOCK
      THE OWNER OUT OF PRODUCTION**, and until now nothing could undo it. A cookie
      that is refused looks exactly like being signed out: there is no token to
      inspect and no header to retry with. The only operator tasks were the GDPR
      erase and lookup, neither of which touches sessions.

      Revokes every live session family for the operator and deletes their
      `guardian_tokens` rows, so the next sign-in starts clean. It does NOT mint a
      session: a task that handed out a credential over `rpc` would be a far more
      attractive target than the lockout it fixes, and the operator can sign in
      normally once the stale state is gone.

      ⚠️ **Guarded by a confirmation IN THE PAYLOAD, not by an environment
      variable.** The pattern `seed_live/0` uses — a flag the node is deployed
      with — is wrong here: this task must work on production, which is the only
      place the lockout matters, so a guard production never carries would make
      it useless exactly when it is needed.

      ⛔ An env var set on the invocation does not work either, and this is
      measured rather than assumed. The documented transport is `rpc` — chosen
      because `eval` starts a second BEAM and OOMs a 512 MB machine — and `rpc`
      evaluates inside the **already-running node**, which never sees the
      invoking shell's environment. On a deployed stack, 2026-11-07, with
      `STACKS_OPERATOR_RECOVERY=1` on the invocation: `printenv` in that shell
      read `1`, and `System.get_env/1` inside the node read **nil**. The guard
      refused every time.

      ⚖️ So the confirmation travels inside the argument, where the boundary
      cannot strip it: `"confirm":"yes-recover-this-operator"`.

      ⚖️ So the guard is deliberately weaker than `seed_live/0`'s, and the reason
      is that the two are protecting against different things. Seeding production
      is never correct, so its gate should be impossible to satisfy there.
      Recovering an operator IS correct on production; the gate exists so it
      cannot happen by accident or by a stray `rpc` in a script.

      Argument is Base64(JSON) like the GDPR tasks, so free text crosses the rpc
      boundary with no shell or Elixir injection surface. Decoded:
      `%{"email" =>, "actor" =>, "reason" =>}`.
  """
  @recovery_confirmation "yes-recover-this-operator"

  @spec recover_operator_access(binary()) :: :ok
  def recover_operator_access(params_b64) when is_binary(params_b64) do
    # ⛔ `ignore: :whitespace`, AND IT IS NOT TIDINESS — THE RUNBOOK'S OWN
    # EXAMPLE PAYLOAD FAILS WITHOUT IT. `base64` wraps at 76 columns by default,
    # and the documented payload (`{"email":…,"actor":…,"reason":…}`) encodes to
    # **two lines**. A bare `Base.decode64!/1` rejects the newline, so an
    # operator following the runbook verbatim got an ArgumentError instead of
    # their account back. ⚖️ A recovery tool should be liberal in what it
    # accepts: the person running it is locked out at the time.
    params = params_b64 |> Base.decode64!(ignore: :whitespace) |> Jason.decode!()
    email = params |> Map.get("email", "") |> to_string() |> String.trim()
    actor = params |> Map.get("actor", "") |> to_string() |> String.trim()
    reason = params |> Map.get("reason", "") |> to_string() |> String.trim()

    # ⛔ THE GUARD IS A FIELD IN THE PAYLOAD, NOT AN ENVIRONMENT VARIABLE, AND
    # THE REASON IS MEASURED RATHER THAN STYLISTIC.
    #
    # This was `System.get_env("STACKS_OPERATOR_RECOVERY") == "1"`, set on the
    # invocation. But the documented transport is `rpc` — deliberately, because
    # `eval` starts a second BEAM and OOMs a 512 MB machine — and **`rpc`
    # evaluates inside the ALREADY-RUNNING node**, which never saw that
    # variable. PROVEN on a deployed stack: with the variable set,
    # `printenv` in the invoking shell read `1` while
    # `System.get_env(...)` inside the node read **`nil`**.
    #
    # ⛔ So the guard could never be satisfied by the documented procedure, and
    # the recovery path — the one thing standing between an operator and a
    # permanent lockout — refused every single time. A guard that cannot be
    # satisfied is not a strong guard; it is a broken feature.
    #
    # ⚖️ A payload field achieves exactly what the env var was for. The
    # docstring's requirement is that it "cannot fire from a stray `rpc` in a
    # script or a workflow, but can always be satisfied by someone who means
    # to, standing at a shell" — and a confirmation nobody types by accident
    # does that, while crossing the rpc boundary by construction because it
    # travels inside the argument.
    if Map.get(params, "confirm") != @recovery_confirmation do
      raise "refusing to recover operator access: add " <>
              ~s("confirm":"#{@recovery_confirmation}") <>
              " to the payload to confirm this is deliberate.\n" <>
              "(An environment variable cannot be used here: `rpc` runs inside the " <>
              "already-running node, which does not see the invocation's environment.)"
    end

    if email == "", do: raise("operator recovery aborted: email is required")
    if actor == "", do: raise("operator recovery aborted: actor is required")
    if reason == "", do: raise("operator recovery aborted: reason is required")

    case Accounts.get_user_by_email(email) do
      nil ->
        # ⚠️ Says the email rather than hiding it. This is an operator task run by
        # someone holding shell access; the enumeration concern that shapes the
        # public auth endpoints does not apply, and a silent no-op here would
        # leave an operator unsure whether the task worked.
        IO.puts("OPERATOR_RECOVERY_ERROR no user with email=#{email}")
        raise "operator recovery aborted: no user with that email"

      user ->
        :ok = Accounts.revoke_all_user_sessions(user.id)

        # ⛔ The audit row names the ACTOR, not the subject, and both are recorded.
        # A row saying only "this account's sessions were revoked" cannot answer
        # the question an auditor actually asks, which is who did it.
        Audit.log(user.id, "operator.access_recovered",
          resource_type: "user",
          resource_id: user.id,
          metadata: %{"actor" => actor, "reason" => reason}
        )

        IO.puts("OPERATOR_RECOVERY_OK user_id=#{user.id} email=#{email} actor=#{actor}")
        :ok
    end
  end

  @doc """
      Operator-run GDPR erasure for ONE user, by `user_id` only, driven by the
      `gdpr-erase-user` workflow. The argument is Base64(JSON) so arbitrary reason
      text crosses the rpc boundary with no shell/Elixir injection surface.
      Decoded: `%{"user_id" =>, "reason" =>, "actor" =>, "dry_run" =>}`.
  """
  @spec gdpr_erase_user(binary()) :: :ok
  def gdpr_erase_user(params_b64) when is_binary(params_b64) do
    params = params_b64 |> Base.decode64!(ignore: :whitespace) |> Jason.decode!()
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
    params = params_b64 |> Base.decode64!(ignore: :whitespace) |> Jason.decode!()
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

  @doc """
      Refreshes the platform cost figures, for the `scheduled-core-jobs`
      workflow.

      ⚠️ This exists because the Oban crontab entry it replaces could not be
      relied on. `deploy/fly.core.toml` sets `min_machines_running = 0`, and
      Oban's `Cron` plugin computes due jobs on a tick from a RUNNING node with
      no catch-up pass — so a 06:00 entry fires only if something else happened
      to wake the machine at 06:00, and a machine woken at 06:03 never runs it.
      The schedule was a lottery weighted by inbound traffic.

      A named release task rather than an `rpc` reaching into the worker: the
      workflow gets a stable entry point, and the contract between the two (what
      it prints, what it raises on) lives here next to the code rather than in a
      quoted shell string.

      Returns `:ok` and prints `COSTS_REFRESH_ITEMS <n>` on success; RAISES on
      failure, because a workflow's exit status is the only thing a schedule can
      act on, and a task that reports a problem by printing it would be green.
  """
  @spec refresh_costs() :: :ok
  def refresh_costs do
    case RefreshCostsJob.perform(%Oban.Job{args: %{}}) do
      :ok ->
        # Counted at the far end, from the table, not from the job's own report
        # of what it did. The two agreeing is the point: this project has
        # shipped a structurally complete pipeline that delivered nothing while
        # every status it reported was green.
        count = Repo.aggregate(PlatformCost, :count)
        IO.puts("COSTS_REFRESH_ITEMS #{count}")
        :ok

      {:error, reason} ->
        IO.puts("COSTS_REFRESH_ERROR #{inspect(reason)}")
        raise "costs refresh failed: #{inspect(reason)}"
    end
  end

  @doc """
      Runs the weekly bookstore-events discovery sweep, for the
      `scheduled-core-jobs` workflow. Same reason as `refresh_costs/0`: the
      crontab entry it replaces fired only if the sleeping machine happened to
      be awake on a Monday at 07:30.

      Prints `BOOKSTORE_EVENTS_SWEEP ok` on success. The sweep itself tolerates
      individual store failures by design — a bookshop with no events page is
      not an error — so this reports completion of the sweep, not a count of
      events found; the worker logs its own per-store tally.
  """
  @spec discover_bookstore_events() :: :ok
  def discover_bookstore_events do
    :ok = DiscoverBookstoreEventsJob.perform(%Oban.Job{args: %{"batch" => true}})
    IO.puts("BOOKSTORE_EVENTS_SWEEP ok")
    :ok
  end

  @doc """
      The retention and account-lifecycle duties, each invoked by name from
      `scheduled-core-jobs.yml`.

      ⚠️ These exist because `Oban.Plugins.Cron` computed them on a tick from a
      running node, on an app whose `min_machines_running` is 0. The plugin has
      no catch-up pass, so an entry fired only if something else happened to
      wake the machine in that minute — a machine woken at 02:03 never ran the
      02:00 entry. Production's `oban_jobs` showed what that looked like: every
      retention row inserted at exactly 02:00:00, picked up within a second,
      and frozen at attempt 1 with a different node UUID each night.

      ⚠️ Named functions rather than one `run_duty(SomeWorker)` entry point,
      because the caller is a shell inside an ssh command string inside a
      workflow, and every layer of that chain re-reads quoting. A bare call
      survives it; a call with a module argument is where nine attempts at one
      remote expression were lost.
  """
  @spec sweep_images() :: :ok
  def sweep_images, do: run_duty(ImageRetentionJob, "IMAGE_RETENTION")

  @spec sweep_exports() :: :ok
  def sweep_exports, do: run_duty(ExportRetentionJob, "EXPORT_RETENTION")

  @spec sweep_import_rows() :: :ok
  def sweep_import_rows, do: run_duty(LibraryImportRowRetentionJob, "IMPORT_ROW_RETENTION")

  @doc """
      ⛔ The one duty in this group that needs the OWNER, and it is the
      least-privilege design working rather than failing.

      `stacks_app` holds INSERT and nothing else on `audit.audit_log` — the
      append-only guarantee is the point — so it can neither read the rows it
      would sweep nor delete them. Measured on a deployed stack: invoked with
      `rpc`, which runs in the app's node as the runtime role, this returned
      `ERROR 42501 permission denied for table audit_log`.

      ⚠️ So it must be invoked with `eval`, which spawns its own BEAM where the
      repo is not yet started and `with_owner_repo/2` can point it at the owner
      connection. That puts audit retention in the same family as `migrate/0`
      and `correct_data/1`: an operator action, not application work.

      ⚠️ Had this been wired as `rpc` AND wrapped in `with_owner_repo/2`, the
      guard in that function would have refused with a message naming the cause
      instead of a privilege error from three frames down — which is what the
      guard is for.
  """
  @spec sweep_audit_log() :: :ok
  def sweep_audit_log do
    load_app()

    {:ok, :ok, _apps} =
      with_owner_repo(Repo, fn _repo -> run_duty(AuditRetentionJob, "AUDIT_RETENTION") end)

    :ok
  end

  @doc """
      Drops LLM call records past their 30-day retention.

      ⚠️ A SCHEDULED DUTY, because a retention policy that only runs when
      someone remembers is a retention policy in name. The bound on
      `raw_response` limits what one response can write; this is what limits how
      long any of it is kept.
  """
  @spec sweep_llm_call_log() :: :ok
  def sweep_llm_call_log, do: run_duty(LlmCallLogRetentionJob, "LLM_CALL_LOG_RETENTION")

  @spec sweep_guardian_tokens() :: :ok
  def sweep_guardian_tokens, do: run_duty(GuardianTokenSweepJob, "GUARDIAN_TOKEN_SWEEP")

  @spec sweep_unverified_accounts() :: :ok
  def sweep_unverified_accounts,
    do: run_duty(ExpiredUnverifiedAccountsJob, "UNVERIFIED_ACCOUNTS_SWEEP")

  @spec sweep_expired_invites() :: :ok
  def sweep_expired_invites, do: run_duty(ExpiredInvitesSweepJob, "EXPIRED_INVITES_SWEEP")

  @spec sweep_lapsed_email_changes() :: :ok
  def sweep_lapsed_email_changes, do: run_duty(ExpiredEmailChangesJob, "EMAIL_CHANGES_SWEEP")

  # ⛔ Prints the count of work REMAINING, read back from the far end after the
  # sweep, not the count the job reports having done.
  #
  # Several of these drain under a budget or a batch ceiling and return `:ok`
  # with rows still past their window — `ImageRetentionJob` logs that it hit its
  # deadline, `AuditRetentionJob` that it hit `@max_batches`. So "the job
  # succeeded" and "the sweep is finished" are different facts, and a workflow
  # that checked only the former would report green over a growing backlog.
  # That is not hypothetical: production held 6,655 expired image rows behind a
  # nightly `:ok`, the oldest 151 days past expiry.
  #
  # ⚠️ Each `pending_count/0` lives beside its own sweep and shares that sweep's
  # predicate, so this number cannot drift into disagreeing with the thing it
  # measures. The drift direction is what matters: a restated predicate reports
  # all-clear while the sweep disagrees, hiding exactly the backlog it exists
  # to reveal.
  @spec run_duty(module(), String.t()) :: :ok
  defp run_duty(worker, sentinel) do
    :ok = worker.perform(%Oban.Job{args: %{}})

    remaining = worker.pending_count()
    IO.puts("#{sentinel} remaining=#{remaining}")

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
      with_owner_repo(primary_repo, fn _repo -> do_seed_prod(email, password) end)

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
      with_owner_repo(primary_repo, fn _repo -> do_seed_prober(email, password) end)

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
