defmodule Stacks.RlsEnforcementTest do
  @moduledoc """
  Row-level security, proven ENFORCED rather than merely configured.

  ⛔ WHAT THIS CLOSES. Until now every test here connected as a superuser, which
  bypasses row-level security, so the policies protecting user data were
  unenforced in `MIX_ENV=test` and the suite could not tell. The consequence was
  a 500 on a deployed stack — queries running before the scope was set — behind
  4150 green tests, every Elixir gate, and `check-rls-scope.sh` itself, which
  asks whether a module scopes ANYWHERE rather than whether each query is
  covered.

  ⚠️ WHAT THIS DOES NOT CLOSE, stated so a green run is not over-read. These
  cases prove the POLICIES enforce and that a specific code path is scoped. They
  do not sweep every query in the application — a path with no test here is
  still unproven, exactly as before. The deployed drive remains the only
  instrument that covers everything, and this one covers what it names.
  """

  use Core.DataCase, async: false

  import Stacks.Factory

  alias Core.AppRole
  alias Core.Repo
  alias Ecto.Adapters.SQL
  alias Stacks.Scope

  @unscoped_refusal "no request scope set"

  describe "the policies actually enforce" do
    test "an unscoped read of a secured table is REFUSED, not silently empty" do
      # ⛔ The distinction is the whole point. A policy that returned zero rows
      # would be indistinguishable from an empty database, and every caller
      # would read "no data" as a fact about the user rather than about its own
      # missing scope. This project's `current_scope()` raises instead.
      assert_raise Postgrex.Error, fn ->
        AppRole.as_app_role(fn ->
          SQL.query!(Repo, "SELECT count(*) FROM op.bookshelves", [])
        end)
      end
    end

    test "the refusal names the scope, so a reader knows what is missing" do
      error =
        assert_raise Postgrex.Error, fn ->
          AppRole.as_app_role(fn ->
            SQL.query!(Repo, "SELECT count(*) FROM op.bookshelves", [])
          end)
        end

      assert error.postgres.message =~ @unscoped_refusal
    end

    test "a scoped read sees the scoped user's own rows" do
      owner = insert(:user)
      insert(:bookshelf, user: owner, name: "library")

      count =
        Scope.with_user(owner.id, fn ->
          AppRole.as_app_role(fn ->
            %{rows: [[n]]} = SQL.query!(Repo, "SELECT count(*) FROM op.bookshelves", [])
            n
          end)
        end)

      assert count >= 1, "the owner's own bookshelf must be visible under their own scope"
    end

    # ⛔ THE DISCRIMINATING CASE. Without it everything above passes against a
    # policy that simply lets a scoped user see EVERYTHING, which would be no
    # protection at all.
    test "a scoped read does NOT see another user's rows" do
      owner = insert(:user)
      other = insert(:user)
      insert(:bookshelf, user: other, name: "library")

      visible =
        Scope.with_user(owner.id, fn ->
          AppRole.as_app_role(fn ->
            %{rows: [[n]]} =
              SQL.query!(
                Repo,
                "SELECT count(*) FROM op.bookshelves WHERE user_id = $1",
                [Ecto.UUID.dump!(other.id)]
              )

            n
          end)
        end)

      assert visible == 0,
             "#{owner.id} could see #{visible} of another user's bookshelves — the policy is not isolating"
    end
  end

  describe "the helper cannot report enforcement it did not measure" do
    # ⛔ The anti-vacuity half, and it is not optional. If `SET ROLE` silently
    # did nothing, every case above would run as a superuser and pass while
    # measuring nothing — the defect class this whole area keeps producing. So
    # the role switch is asserted rather than assumed.
    test "the role really drops, and really comes back" do
      assert AppRole.superuser?(), "the suite's own connection should still be a superuser"

      inside =
        AppRole.as_app_role(fn ->
          %{rows: [[role, super?]]} =
            SQL.query!(
              Repo,
              "SELECT current_user::text, (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)",
              []
            )

          {role, super?}
        end)

      assert inside == {"stacks_app", false},
             "inside the block the connection must be a non-superuser, or policies are bypassed"

      assert AppRole.superuser?(),
             "RESET ROLE must restore the connection, or later fixtures are written as the wrong role"
    end

    test "the role is restored even when the block raises" do
      assert_raise RuntimeError, fn ->
        AppRole.as_app_role(fn -> raise "boom" end)
      end

      assert AppRole.superuser?(),
             "an exception inside the block must not leave the connection de-privileged"
    end
  end

  describe "a real code path is covered, not just the policies" do
    # ⛔ THIS IS THE CASE THAT JUSTIFIES THE HARNESS. The deployed defect was not
    # a missing policy — the policies were correct. It was ORDERING: queries in
    # `Shelving` ran before the `Ecto.Multi` step that set the scope, so they
    # hit secured tables unscoped. `check-rls-scope.sh` cannot see intra-function
    # ordering, and a superuser suite cannot see it at all.
    #
    # Driving a real write through the least-privilege role is what makes that
    # ordering observable offline.
    test "a scoped Shelving READ runs entirely within the scope" do
      owner = insert(:user)
      insert(:bookshelf, user: owner, name: "library")

      # ⚠️ A READ rather than a write, deliberately. The deployed defect was
      # seven placement LOOKUPS and three `get_or_create_bookshelf/2` calls
      # running before the scope was set, so reads are the shape that matters —
      # and driving a full `Ecto.Multi` write under `SET LOCAL ROLE` inside the
      # sandbox hits transaction semantics this harness does not resolve (the
      # Multi's abort poisons the enclosing transaction). Recorded rather than
      # worked around.
      # ⛔ NO OUTER `Scope.with_user`, and that is the whole point. The first
      # version of this case wrapped the call in one — so the TEST supplied the
      # scope the production function is supposed to supply, and the case passed
      # with the scope stripped out of `get_bookshelf_shelves` entirely.
      # MEASURED: 7/7 green against the planted historical defect.
      #
      # It was proving "RLS enforces when something sets a scope", which the
      # cases above already prove, rather than "this code path sets its own".
      # The production function must establish the scope itself or the query is
      # refused.
      result =
        AppRole.as_app_role(fn ->
          Stacks.Shelving.get_bookshelf_shelves(owner.id, "library")
        end)

      refute match?({:error, _}, result),
             """
             a Shelving read was refused while running as the least-privilege role: \
             #{inspect(result)}

             A 42501 / "no request scope set" here means some query on this path runs OUTSIDE
             the scope — the deployed-500 defect, now visible offline. The fix belongs at the
             shared helper the query goes through, not at the call site.
             """
    end
  end
end
