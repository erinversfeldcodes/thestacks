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

    # ⚠️ A repo NAME that is not started, which is the state every caller of the
    # wrapper runs in — all six are invoked with `eval`, in their own BEAM.
    #
    # Nothing here needs it to be a real repo: the swap is keyed by module name
    # in the application environment, and the started-ness guard asks
    # `GenServer.whereis/1`, which answers `nil` for an unregistered name. Using
    # the live `Core.Repo` instead would now RAISE — see the refusal test below,
    # which is the one case that deliberately uses the started repo.
    @unstarted_repo Core.Repo.UnstartedForConfigAssertions

    # Reads the url the wrapper leaves in config while the function runs, which
    # is the only thing that decides where a pool would connect.
    defp url_seen_inside(repo, configured) do
      previous = Application.get_env(:core, repo, [])

      try do
        Application.put_env(:core, repo, Keyword.put(previous, :url, configured))

        Stacks.Release.with_owner_repo_config(repo, fn ->
          Application.get_env(:core, repo)[:url]
        end)
      after
        Application.put_env(:core, repo, previous)
      end
    end

    test "a release task takes the OWNER url even while the app url is set" do
      with_env(
        [
          {"DATABASE_URL", "ecto://owner:x@db.test/owner_db"},
          {"APP_DATABASE_URL", "ecto://stacks_app:x@db.test/app_db"}
        ],
        fn ->
          seen = url_seen_inside(@unstarted_repo, "ecto://stacks_app:x@db.test/app_db")

          assert seen == "ecto://owner:x@db.test/owner_db",
                 "a release task would connect as the RUNTIME role. `migrate/0` runs DDL and " <>
                   "needs ownership, so setting APP_DATABASE_URL would break the next deploy's " <>
                   "migration step while the app kept serving — the failure arriving whenever " <>
                   "somebody next deploys, not when the secret was set"
        end
      )
    end

    test "with no owner url the repo's own config is left alone, so dev and test are untouched" do
      # ⚠️ Stronger than the `== []` this replaces, and that is the point of
      # driving the wrapper rather than the helper behind it: an empty option
      # list is a claim about an intermediate value, while the property
      # one-role environments actually depend on is that their configured url
      # SURVIVES the call. Asserted with APP_DATABASE_URL set, because that is
      # the case where a naive implementation reaches for the wrong one.
      with_env([{"APP_DATABASE_URL", "ecto://stacks_app:x@db.test/app_db"}], fn ->
        previous = System.get_env("DATABASE_URL")
        System.delete_env("DATABASE_URL")

        try do
          seen = url_seen_inside(@unstarted_repo, "ecto://dev:x@localhost/stacks_dev")

          assert seen == "ecto://dev:x@localhost/stacks_dev",
                 "with no owner url the wrapper still rewrote the repo's config — dev and test " <>
                   "have one role and their own config is already right, so there is nothing to " <>
                   "override and no url to invent"
        after
          if previous, do: System.put_env("DATABASE_URL", previous)
        end
      end)
    end

    test "an empty owner url is treated as absent, not as a url" do
      with_env([{"DATABASE_URL", ""}], fn ->
        seen = url_seen_inside(@unstarted_repo, "ecto://dev:x@localhost/stacks_dev")

        assert seen == "ecto://dev:x@localhost/stacks_dev",
               "an empty DATABASE_URL became a url override, which would make a release task " <>
                 "try to connect to nothing"
      end)
    end

    test "⛔ it REFUSES to run against a started repo while the split is active" do
      # ⛔ The shape in which this defect comes back. With the split active the
      # started pool is on the least-privilege role, so writing the owner url
      # into config cannot move it: the swap succeeds, the task runs as
      # `stacks_app` anyway, and the only symptom is a `permission denied`
      # later, somewhere that does not name the config as the cause. Silently
      # doing nothing useful is worse than stopping, so it stops.
      #
      # ⚠️ The `whereis` assertion is the anti-vacuity floor. If the repo were
      # not started in this environment, the raise could never fire and this
      # test would pass while proving nothing at all.
      assert GenServer.whereis(Core.Repo),
             "Core.Repo is not started here, so this test cannot tell a working guard from a " <>
               "missing one"

      with_env(
        [
          {"DATABASE_URL", "ecto://owner:x@db.test/owner_db"},
          {"APP_DATABASE_URL", "ecto://stacks_app:x@db.test/app_db"}
        ],
        fn ->
          before = Application.get_env(:core, Core.Repo)[:url]

          error =
            assert_raise RuntimeError, fn ->
              Stacks.Release.with_owner_repo_config(Core.Repo, fn -> :never_runs end)
            end

          assert error.message =~ "already started",
                 "it raised, but not about the thing that is wrong"

          assert error.message =~ "eval",
                 "the message does not say how to run a release task correctly, which is the " <>
                   "whole reason to raise instead of proceeding"

          assert Application.get_env(:core, Core.Repo)[:url] == before,
                 "the refusal still rewrote the live repo's config on its way out"
        end
      )
    end

    test "⚠️ a started repo is NOT refused while the split is inactive" do
      # ⛔ The condition that had to be added after the broad guard broke six
      # passing tests. `seed_prod/0` and `seed_prober/0` are called in-process
      # by `release_test.exs` against the started test repo — a correct caller,
      # because with `APP_DATABASE_URL` unset the runtime pools are on the owner
      # already and the swap had nothing to achieve.
      #
      # ⚠️ So this is not a convenience case. A guard that fires where the
      # override was never needed is a block on correct callers, which is worse
      # than the silent no-op it set out to prevent.
      assert GenServer.whereis(Core.Repo), "the floor: an unstarted repo proves nothing here"

      previous_app = System.get_env("APP_DATABASE_URL")
      System.delete_env("APP_DATABASE_URL")

      try do
        with_env([{"DATABASE_URL", "ecto://owner:x@db.test/owner_db"}], fn ->
          assert Stacks.Release.with_owner_repo_config(Core.Repo, fn -> :ran end) == :ran,
                 "a started repo was refused with the split inactive, so every in-process " <>
                   "caller — and the suite that tests them — cannot run a release task at all"
        end)
      after
        if previous_app, do: System.put_env("APP_DATABASE_URL", previous_app)
      end
    end

    test "⚠️ an APP_DATABASE_URL equal to the owner url is not a split at all" do
      # The fallback shape. `runtime.exs` resolves an unset APP_DATABASE_URL to
      # the owner url, so a stack that sets the secret to the SAME value has
      # pools on the owner — identical to not setting it. Refusing there would
      # read as the split being active when it is not.
      assert GenServer.whereis(Core.Repo), "the floor: an unstarted repo proves nothing here"

      with_env(
        [
          {"DATABASE_URL", "ecto://owner:x@db.test/owner_db"},
          {"APP_DATABASE_URL", "ecto://owner:x@db.test/owner_db"}
        ],
        fn ->
          assert Stacks.Release.with_owner_repo_config(Core.Repo, fn -> :ran end) == :ran,
                 "an APP_DATABASE_URL identical to the owner url was treated as a live split, " <>
                   "so a stack whose pools are already the owner is refused"
        end
      )
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

    test "the helper still exists, is PRIVATE, and still reads the owner variable" do
      # Kept as a source assertion deliberately: it guards the NAME the
      # deploy scripts and workflows compose, which no behavioural test can see.
      src = release_src()
      assert src =~ ~s|System.get_env("DATABASE_URL")|, "it does not read DATABASE_URL"
      assert src =~ "defp owner_repo_opts", "the helper is gone"

      # ⚠️ Private on purpose. A public options-returning function invited the
      # original defect — it reads as the thing that applies the override, and
      # it was passed to a function that discarded it from seven call sites. The
      # only safe way to reach it is through the wrapper that also APPLIES it,
      # so the options never exist as something a caller can hold and misuse.
      refute src =~ ~r/\n  def owner_repo_opts/,
             "the options helper is public again, which is the surface the discarded-option " <>
               "defect was written against"
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
