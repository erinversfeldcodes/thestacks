defmodule Core.DatabaseRoleSplitTest do
  @moduledoc """
      Two database roles, one connection string each, and the invariant that
      keeps the split from taking a stack down.

      `docs/rls-design.md` specifies a least-privilege `stacks_app` role —
      CRUD on `op`, SELECT on `marts`, INSERT-only on `audit`, and the role the
      RLS policies are evaluated against. The roles existed and nothing
      connected as them, so every grant ever written was decorative on the only
      connection that matters.

      The split: `DATABASE_URL` keeps its existing meaning (the OWNER, needed
      for DDL), and `APP_DATABASE_URL` is the new least-privilege RUNTIME
      connection, falling back to the owner when unset.

      ## The two properties this file exists to pin

      **1. The fallback.** Unset, the runtime pools must use the owner URL, so
      the change is byte-identical to the previous behaviour on arrival. That is
      what makes it safe to merge with everything else: switching becomes an
      operator action (set one secret), reverting becomes unsetting it, and a
      merge cannot be broken by a change that does nothing until a secret
      appears.

      **2. Release tasks must NOT inherit the runtime URL.** ⚠️ This is the one
      that bites. Every task in `Stacks.Release` does something a
      least-privilege role cannot — `migrate/0` runs DDL, which requires
      ownership. If a release task took the repo's configured URL, then setting
      `APP_DATABASE_URL` would leave the app serving happily and make the NEXT
      deploy's migration step fail on `permission denied`. The change would look
      inert right up to the moment it took the stack down, which is the worst
      shape a flag can have: the failure is separated from its cause by however
      long it is until someone deploys.
  """

  use ExUnit.Case, async: true

  @runtime_config Path.expand("../../../../config/runtime.exs", __DIR__)
  @release_module Path.expand("../../lib/stacks/release.ex", __DIR__)
  @migrations Path.expand("../../priv/repo/migrations", __DIR__)

  defp runtime_src, do: File.read!(@runtime_config)
  defp release_src, do: File.read!(@release_module)

  describe "the runtime pools" do
    test "both repos read APP_DATABASE_URL, not DATABASE_URL directly" do
      src = runtime_src()

      assert src =~ ~s|System.get_env("APP_DATABASE_URL")|,
             "config/runtime.exs does not read APP_DATABASE_URL at all, so the least-privilege " <>
               "role has no way to be used and every grant on it stays decorative"

      # ⚠️ Asserted on the ASSIGNMENT both pools share, not merely on the
      # variable existing. A config that computed `app_database_url` and then
      # pointed the pools at `database_url` anyway would satisfy a looser check
      # while changing nothing — and would read as done.
      for repo <- ["Core.Repo", "Core.ObanRepo"] do
        block = config_block(src, repo)

        assert block =~ "url: app_database_url",
               "#{repo} is not configured with app_database_url, so it keeps connecting as the " <>
                 "owner no matter what APP_DATABASE_URL says:\n#{block}"
      end
    end

    test "the app role is granted on every schema the runtime pools actually touch" do
      # ⛔ The test above establishes that BOTH pools read `app_database_url`,
      # and that is precisely what makes this necessary. `Core.ObanRepo` is one
      # of them, and Oban's tables live in `public` — while the roles migration
      # grants on `op`, `audit` and the warehouse schemas and never mentions
      # `public`.
      #
      # Measured on production and on a preview carrying the full campaign
      # migration set, `stacks_app` held NO privilege on `public.oban_jobs`, none
      # on `public.oban_peers`, and no USAGE on `public.oban_jobs_id_seq`. So
      # setting the secret would have stopped every background job: nothing
      # insertable, claimable, prunable or rescuable.
      #
      # ⚠️ The fallback is what hid it. Unset, both pools use the owner URL, so
      # the least-privilege path has never executed on any stack — the first run
      # would have been production. A source assertion is the only offline way to
      # keep that from coming back, because no local or CI run exercises it.
      grants =
        @migrations
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".exs"))
        |> Enum.map_join("\n", &File.read!(Path.join(@migrations, &1)))

      # Matched on the grant TARGET rather than the grantee, because the
      # migration names the role through an interpolated attribute; the target
      # is the part that is literal either way.
      assert grants =~ "ON public.oban_jobs TO",
             "no migration grants stacks_app DML on public.oban_jobs. Both runtime pools read " <>
               "APP_DATABASE_URL, so setting it would leave Oban unable to touch its own tables " <>
               "and every background job would stop."

      # The sequence is a separate grant and the easy one to miss: without USAGE
      # on it the role can read and delete jobs but never enqueue one, which is
      # a half-working queue rather than an obvious failure.
      # ⚠️ Must match a GRANT specifically, not the sequence name anywhere. A
      # looser `grants =~ "oban_jobs_id_seq"` passed a planted probe that removed
      # the grant entirely, because the REVOKE in the migration's `down` path
      # still mentions the sequence — the assertion was satisfied by the rollback
      # of the thing it was meant to require.
      assert grants =~ ~r/GRANT[^;]*\bON\s+SEQUENCE\s+public\.oban_jobs_id_seq\b/,
             "no migration GRANTs stacks_app usage on public.oban_jobs_id_seq. INSERT needs it, " <>
               "so the role could read and prune jobs but never enqueue one."

      # ⛔ And the runtime role must NOT be able to rewrite migration history,
      # which lives in the same schema the grants above open up.
      assert grants =~ ~r/REVOKE\s+ALL\s+ON\s+public\.schema_migrations/,
             "nothing revokes the app role's access to public.schema_migrations. Granting on " <>
               "the public schema without this hands the runtime role the ability to rewrite " <>
               "migration history."
    end

    test "an unset APP_DATABASE_URL falls back to the owner URL" do
      # The property that makes this mergeable: inert on arrival. Read off the
      # fallback expression rather than by booting a second repo, because the
      # config is evaluated once at boot and there is nothing to re-evaluate.
      assert runtime_src() =~ ~s<System.get_env("APP_DATABASE_URL") || database_url>,
             "the APP_DATABASE_URL read has no fallback to database_url. Without it, a stack " <>
               "that has not had the new secret set would boot with a nil URL — so merging this " <>
               "change would break every environment that had not been prepared first, which is " <>
               "the opposite of the intent"
    end
  end

  describe "release tasks pin the owner connection" do
    # ⛔ These three are BEHAVIOURAL, and that is the whole point of them.
    #
    # The assertion they replace was `owner_repo_opts() == [] or
    # Keyword.has_key?(..., :url)` — satisfied by almost any keyword list, and
    # it never set `APP_DATABASE_URL` at all, so it could not tell the owner URL
    # from the app URL even in principle. Everything else about this split was
    # asserted from SOURCE TEXT, which is the exact weakness the
    # least-privilege work recorded as its open risk: if the selection were ever
    # wrong, setting one secret would leave the app serving happily and break
    # the NEXT deploy's migration step, separating the failure from its cause by
    # however long it is until someone deploys.
    #
    # ⚠️ `async: false` is not available here (the module is `async: true`), so
    # these set and restore the two variables around each assertion rather than
    # in a setup block, and they use values no real URL could collide with.
    defp with_env(vars, fun) do
      previous = Map.new(vars, fn {name, _} -> {name, System.get_env(name)} end)

      try do
        Enum.each(vars, fn {name, value} -> System.put_env(name, value) end)
        fun.()
      after
        Enum.each(previous, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end
    end

    test "a release task takes the OWNER url even while the app url is set" do
      with_env(
        [
          {"DATABASE_URL", "ecto://owner:x@db.test/owner_db"},
          {"APP_DATABASE_URL", "ecto://stacks_app:x@db.test/app_db"}
        ],
        fn ->
          opts = Stacks.Release.owner_repo_opts()

          assert Keyword.fetch!(opts, :url) == "ecto://owner:x@db.test/owner_db",
                 "a release task would connect as the RUNTIME role. `migrate/0` runs DDL and " <>
                   "needs ownership, so setting APP_DATABASE_URL would break the next deploy's " <>
                   "migration step while the app kept serving — the failure arriving whenever " <>
                   "somebody next deploys, not when the secret was set"
        end
      )
    end

    test "it is empty when the owner url is absent, so dev and test are untouched" do
      # Empty-when-absent is what keeps one-role environments alone: the repo's
      # own config is already right there, and an override would have to invent
      # a URL. Asserted with APP_DATABASE_URL SET, because that is the case
      # where a naive implementation would reach for the wrong one.
      with_env([{"APP_DATABASE_URL", "ecto://stacks_app:x@db.test/app_db"}], fn ->
        previous = System.get_env("DATABASE_URL")
        System.delete_env("DATABASE_URL")

        try do
          assert Stacks.Release.owner_repo_opts() == [],
                 "with no owner url, a release task must not fall back to the app url"
        after
          if previous, do: System.put_env("DATABASE_URL", previous)
        end
      end)
    end

    test "an empty owner url is treated as absent, not as a url" do
      with_env([{"DATABASE_URL", ""}], fn ->
        assert Stacks.Release.owner_repo_opts() == [],
               "an empty DATABASE_URL became a url override, which would make a release task " <>
                 "try to connect to nothing"
      end)
    end

    test "⛔ the override reaches the CONNECTION, not just the option list" do
      # ⛔ THE TEST THAT WAS MISSING, and its absence took a preview deploy down.
      #
      # The tests above prove `owner_repo_opts/0` RETURNS the owner url. They do
      # not prove anything USES it — and nothing did.
      # `Ecto.Migrator.with_repo/3` reads only `:mode` and `:pool_size` from its
      # options and starts the repo with `repo.start_link(pool_size: pool_size)`,
      # discarding `:url` (ecto_sql 3.14.0, `migrator.ex:817`). So every release
      # task passed an override that was thrown away.
      #
      # It was invisible while `APP_DATABASE_URL` was unset, because then the
      # config pointed at `DATABASE_URL` anyway and the override agreed with the
      # config it was failing to override. The first deploy that set the secret
      # ran the release command as `stacks_app` and aborted on `28P01`.
      #
      # ⚠️ This asserts the only thing that decides where the pool connects: the
      # repo's own config, at the moment `with_owner_repo/2` runs its function.
      with_env(
        [
          {"DATABASE_URL", "ecto://owner:x@db.test/owner_db"},
          {"APP_DATABASE_URL", "ecto://stacks_app:x@db.test/app_db"}
        ],
        fn ->
          previous = Application.get_env(:core, Core.Repo, [])

          try do
            Application.put_env(
              :core,
              Core.Repo,
              Keyword.put(previous, :url, "ecto://stacks_app:x@db.test/app_db")
            )

            seen =
              Stacks.Release.with_owner_repo_config(Core.Repo, fn ->
                Application.get_env(:core, Core.Repo)[:url]
              end)

            assert seen == "ecto://owner:x@db.test/owner_db",
                   "the repo would have STARTED on #{inspect(seen)} — the runtime role. " <>
                     "`with_repo/3` discards a `:url` option, so config is the only channel " <>
                     "that decides where the pool connects"
          after
            Application.put_env(:core, Core.Repo, previous)
          end
        end
      )
    end

    test "the owner config is restored even when the task raises" do
      # ⚠️ A release task is usually the only thing in its BEAM, but a leaked
      # owner url in config is a credential left pointing at the wrong role for
      # whatever runs next. The restore belongs in an `after`, not after the call.
      with_env([{"DATABASE_URL", "ecto://owner:x@db.test/owner_db"}], fn ->
        previous = Application.get_env(:core, Core.Repo, [])

        try do
          Application.put_env(
            :core,
            Core.Repo,
            Keyword.put(previous, :url, "ecto://stacks_app:x@db.test/app_db")
          )

          assert_raise RuntimeError, fn ->
            Stacks.Release.with_owner_repo_config(Core.Repo, fn -> raise "boom" end)
          end

          assert Application.get_env(:core, Core.Repo)[:url] ==
                   "ecto://stacks_app:x@db.test/app_db",
                 "a raising task left the repo config pointed at the owner"
        after
          Application.put_env(:core, Core.Repo, previous)
        end
      end)
    end

    test "every release task goes through the wrapper, not with_repo plus options" do
      # ⛔ A sweep rather than a list of known sites. The defect was that SEVEN
      # call sites each passed an option that did nothing; a task added later
      # that reaches for `with_repo` directly would reintroduce it silently.
      src = release_src()

      refute src =~ ~r/Ecto\.Migrator\.with_repo\([^)]*owner_repo_opts\(\)/s,
             "a release task still passes owner_repo_opts() to with_repo/3, which discards it"

      assert src =~ "def with_owner_repo", "the wrapper is gone"
    end

    test "the helper still exists and still reads the owner variable" do
      # Kept as a source assertion deliberately: it guards the NAME the
      # deploy scripts and workflows compose, which no behavioural test can see.
      src = release_src()
      assert src =~ ~s|System.get_env("DATABASE_URL")|, "it does not read DATABASE_URL"
      assert src =~ "def owner_repo_opts", "the helper is gone"
    end

    test "⚠️ the sweep this replaces was pinning the BROKEN mechanism" do
      # ⛔ Worth recording rather than silently deleting. The test that used to
      # sit here asserted that EVERY `Ecto.Migrator.with_repo` call in
      # `Stacks.Release` passed `owner_repo_opts()` as its third argument. It was
      # a careful test — a sweep rather than a hand-listed roster, with an
      # anti-vacuity floor on the number of call sites it found — and it held
      # firmly for as long as it existed.
      #
      # It was guarding the wrong thing. `with_repo/3` discards that argument, so
      # the test pinned seven call sites into a pattern that did nothing, and
      # made the real defect harder to see: anyone checking "is the override
      # applied?" found a green, thorough-looking assertion saying yes.
      #
      # ⚠️ The lesson is not "write better tests". It is that a test asserting a
      # CALL SHAPE cannot tell you the call has an EFFECT, however rigorous it is
      # about the shape. The replacement above asserts the effect — what the
      # repo's config says at the moment the function runs.
      src = release_src()

      refute src =~ "owner_repo_opts()\n        )",
             "a with_repo call is passing the discarded options argument again"

      assert src =~ "def with_owner_repo_config",
             "the config swap — the only thing that changes where a pool connects — is gone"
    end
  end

  # The `config :core, <repo>, …` block, up to the next blank line, so an
  # assertion about one repo cannot be satisfied by the other's settings.
  defp config_block(src, repo) do
    src
    |> String.split("config :core, #{repo},", parts: 2)
    |> Enum.at(1, "")
    |> String.split("\n\n", parts: 2)
    |> hd()
  end
end
