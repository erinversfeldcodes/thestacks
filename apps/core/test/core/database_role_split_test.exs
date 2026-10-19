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
    test "owner_repo_opts/0 reads DATABASE_URL and is empty when it is absent" do
      # Empty-when-absent keeps dev and test untouched: there is one role there,
      # the repo's own config is already right, and an override would have to
      # invent a URL.
      assert Stacks.Release.owner_repo_opts() == [] or
               Keyword.has_key?(Stacks.Release.owner_repo_opts(), :url),
             "owner_repo_opts/0 returned something that is neither empty nor a url override"

      src = release_src()
      assert src =~ ~s|System.get_env("DATABASE_URL")|, "it does not read DATABASE_URL"
      assert src =~ "def owner_repo_opts", "the helper is gone"
    end

    test "EVERY with_repo call in Stacks.Release passes the owner options" do
      # ⚠️ The load-bearing assertion, and it is deliberately a sweep rather
      # than a list of known call sites. A task added later that forgets the
      # override is the exact regression this file is about, and a hand-listed
      # roster would not see it — the same instance-not-class error this
      # campaign has hit repeatedly.
      src = release_src()

      calls =
        src
        |> String.split("Ecto.Migrator.with_repo")
        |> tl()

      assert length(calls) >= 6,
             "found #{length(calls)} with_repo call(s) in Stacks.Release — expected at least six, " <>
               "so this sweep is no longer reading the module it is written for"

      unpinned =
        calls
        |> Enum.with_index(1)
        |> Enum.reject(fn {tail, _index} ->
          # The options are the third argument, so they appear before the call's
          # own closing — look only at the text up to the next `end`-of-call
          # marker rather than at the whole rest of the file.
          tail
          |> String.split(~r/\n  (?:end|@doc|def |defp )/, parts: 2)
          |> hd()
          |> String.contains?("owner_repo_opts()")
        end)
        |> Enum.map(fn {_tail, index} -> index end)

      assert unpinned == [],
             "with_repo call(s) #{inspect(unpinned)} in Stacks.Release do not pass " <>
               "owner_repo_opts(). A release task that inherits the runtime URL runs as " <>
               "stacks_app, which cannot execute DDL — so setting APP_DATABASE_URL would leave " <>
               "the app serving and break the next deploy's migration step, separating the " <>
               "failure from its cause by however long it is until someone deploys."
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
