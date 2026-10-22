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
  alias Stacks.Shelving.Bookshelf

  @unscoped_refusal "no request scope set"
  @secured_tables ~w(bookshelves bookshelf_placements user_blocks visibility_grants)

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

  describe "writes are refused too, not only reads" do
    # ⛔ I had recorded the write path as UNTESTABLE — the `Ecto.Multi`'s abort
    # poisoning the enclosing transaction. A reviewer thought the blocker was
    # imaginary and the Multi incidental, and was right on both counts.
    #
    # MEASURED: a single `Repo.insert!` exercises the policy's `WITH CHECK`
    # identically, needs no Multi, and the connection is still usable after each
    # refusal — so the constraint is "assert nothing after the raise", not
    # "untestable". The Multi brought savepoint complexity unrelated to the
    # thing under test.
    test "a scoped write of the scoped user's own row is allowed" do
      owner = insert(:user)

      # The positive control. Without it the two refusals below pass against a
      # policy that refuses everything, which would be no guarantee at all.
      assert %Bookshelf{} =
               Scope.with_user(owner.id, fn ->
                 AppRole.as_app_role(fn ->
                   Repo.insert!(%Bookshelf{
                     id: Ecto.UUID.generate(),
                     user_id: owner.id,
                     name: "library",
                     visibility: "owner"
                   })
                 end)
               end)
    end

    test "an UNSCOPED write is refused" do
      owner = insert(:user)

      # ⚠️ `assert_raise` is the LAST statement, asserting nothing after it: the
      # refusal aborts the statement, and while the connection survives here,
      # depending on that would be depending on an implementation detail.
      assert_raise Postgrex.Error, fn ->
        AppRole.as_app_role(fn ->
          Repo.insert!(%Bookshelf{
            id: Ecto.UUID.generate(),
            user_id: owner.id,
            name: "wishlist",
            visibility: "owner"
          })
        end)
      end
    end

    # ⛔ THE WRITE-SIDE ISOLATION GUARANTEE, and it exercises a different clause
    # from everything above. The reads are refused by `USING`; this is refused
    # by `WITH CHECK` — "new row violates row-level security policy" rather than
    # "no request scope set". A policy with `USING` and no `WITH CHECK` would
    # pass every other case in this file and let one user write rows owned by
    # another.
    test "a scoped write of ANOTHER user's row is refused by WITH CHECK" do
      owner = insert(:user)
      other = insert(:user)

      assert_raise Postgrex.Error, fn ->
        Scope.with_user(owner.id, fn ->
          AppRole.as_app_role(fn ->
            Repo.insert!(%Bookshelf{
              id: Ecto.UUID.generate(),
              user_id: other.id,
              name: "antilibrary",
              visibility: "owner"
            })
          end)
        end)
      end
    end
  end

  describe "the write primitive production actually uses" do
    # ⛔ THE HIGHEST-VALUE SINGLE TEST AVAILABLE HERE, and it closes the gap I had
    # recorded as needing a mechanism. I had written off the write path because an
    # `Ecto.Multi`'s abort poisons the enclosing transaction; a reviewer pointed
    # out that a single statement covers the POLICY, and what a Multi covers that
    # a statement cannot is `Scope.multi_step/2` — the primitive every production
    # write uses, and until now unverified under enforcement.
    #
    # ⚖️ And `place_book/5` is the historical defect's exact shape:
    # `get_or_create_bookshelf/2` (`shelving.ex:374`) and
    # `get_or_create_default_shelf/1` (`:376`) run BEFORE the Multi, scoped by
    # `with_user`, and `Scope.multi_step(user_id)` is the Multi's first step
    # (`:380`). So one test exercises the pre-Multi scoped lookups AND
    # `multi_step`, under the least-privilege role, on the function that returned
    # the deployed 500.
    #
    # ⚠️ It needs no abort: this is the SUCCESS case. The "connection survives a
    # refusal" measurement is not load-bearing for the valuable half.
    test "place_book succeeds as the least-privilege role, scoped" do
      owner = insert(:user)
      book = insert(:book)
      edition = insert(:book_edition, book: book)

      # ⛔ NO OUTER `Scope.with_user`, and this is what makes the case
      # discriminate. `place_book/5` is SELF-SCOPING: `get_or_create_bookshelf/2`
      # wraps itself (`shelving.ex:1354`) and `Scope.multi_step/2` scopes the
      # Multi. An outer wrapper supplies the scope the function is supposed to
      # supply, and `SET LOCAL` applies to the outermost transaction — so the
      # Multi inherits it and `multi_step` becomes redundant.
      #
      # MEASURED: with the outer wrapper in place, removing `Scope.multi_step`
      # from that Multi left this test GREEN. Same vacuity as the read case
      # before it — the test providing the precondition it is meant to check.
      result =
        AppRole.as_app_role(fn ->
          Stacks.Shelving.place_book(owner.id, book.id, "library", edition.id)
        end)

      case result do
        {:ok, _} ->
          :ok

        other ->
          flunk("""
          place_book was refused as the least-privilege role: #{inspect(other)}

          ⛔ A 42501 here means some query on this path runs OUTSIDE the scope — either one of the
          two pre-Multi lookups, or the Multi itself if `Scope.multi_step/2` is missing from it.
          That is the deployed-500 defect, now visible offline. The fix belongs at the shared
          helper the query goes through, not at the call site.
          """)
      end
    end
  end

  describe "every secured table isolates, not just the one the other cases touch" do
    # ⛔ CONSULTATION PROVEN BEHAVIOURALLY ON ALL FOUR, which the catalogue tests
    # below cannot do. Those prove the policies EXIST and are FORCED; they say
    # nothing about what the policies say. The owner-sees-own / other-sees-none
    # pair is what proves a policy is consulted, because it cannot both hold on
    # a policy-free table — and until now it existed for `bookshelves` only.
    #
    # ⚖️ Anchored to @secured_tables (the same list the catalogue tests use), so
    # adding a fifth secured table fails here until a pair exists for it.
    # Derived rather than maintained.
    #
    # ⚠️ It is NOT four copies, and the reviewer said so before I found out:
    # `user_blocks` and `visibility_grants` each need a second user plus a
    # block/grant row, and `bookshelf_placements` nests under a bookshelf. The
    # setup is per-table; only the assertion is shared.
    #
    # ⚠️ And the route NOT taken, recorded so nobody re-proposes it: inspecting
    # `EXPLAIN` output for policy quals asserts the PLAN rather than the outcome
    # and breaks on planner changes.
    # Each clause returns the query plus how to name its subject, because the
    # subject is not always a user — see the placements clause for why that
    # distinction is load-bearing rather than tidiness.
    defp by_user_id(user), do: user.id

    defp seed_for("bookshelves", owner, other) do
      insert(:bookshelf, user: owner, name: "library")
      insert(:bookshelf, user: other, name: "library")
      {"SELECT count(*) FROM op.bookshelves WHERE user_id = $1", &by_user_id/1}
    end

    # ⛔ NO JOIN, AND THE SUBJECT IS A BOOKSHELF RATHER THAN A USER. The first
    # version of this pair joined `op.bookshelves` and filtered on
    # `b.user_id`, which made it UNABLE TO DISCRIMINATE THE POLICY IT NAMES:
    # the joined row is itself subject to `bookshelves_owner`, so the
    # other-sees-none half returned 0 because the other user's BOOKSHELF was
    # hidden — whatever `bookshelf_placements_owner` happened to say. Widening
    # the placements policy to `USING (true)` left the pair green.
    #
    # ⚠️ The per-table red drive did not catch it, and that is the instructive
    # part: it was run on `user_blocks`, which has no join, so the one table
    # whose query reached through a second secured table was the one table the
    # probe could not speak to. A probe on a shared assertion proves the
    # assertion, not every arrangement feeding it.
    #
    # Placements carry no `user_id`, so `bookshelf_id` is the column the policy
    # itself discriminates on — which is why naming the subject that way makes
    # the query depend on the placements policy and nothing else.
    defp seed_for("bookshelf_placements", owner, other) do
      shelves =
        for u <- [owner, other], into: %{} do
          shelf = insert(:bookshelf, user: u, name: "library")
          insert(:placement, bookshelf: shelf, book: insert(:book))
          {u.id, shelf.id}
        end

      {"SELECT count(*) FROM op.bookshelf_placements WHERE bookshelf_id = $1",
       fn user -> Map.fetch!(shelves, user.id) end}
    end

    defp seed_for("user_blocks", owner, other) do
      insert(:user_block, blocker: owner, blocked: insert(:user))
      insert(:user_block, blocker: other, blocked: insert(:user))
      {"SELECT count(*) FROM op.user_blocks WHERE blocker_id = $1", &by_user_id/1}
    end

    defp seed_for("visibility_grants", owner, other) do
      insert(:visibility_grant, granted_by: owner, granted_to: insert(:user))
      insert(:visibility_grant, granted_by: other, granted_to: insert(:user))
      {"SELECT count(*) FROM op.visibility_grants WHERE granted_by_id = $1", &by_user_id/1}
    end

    for table <- @secured_tables do
      @table table

      test "op.#{table}: the owner sees their own row and NOT another user's" do
        owner = insert(:user)
        other = insert(:user)
        {sql, subject_id} = seed_for(@table, owner, other)

        count_as = fn scoped_user, subject ->
          Scope.with_user(scoped_user.id, fn ->
            AppRole.as_app_role(fn ->
              %{rows: [[n]]} = SQL.query!(Repo, sql, [Ecto.UUID.dump!(subject_id.(subject))])
              n
            end)
          end)
        end

        assert count_as.(owner, owner) >= 1,
               "op.#{@table}: the owner cannot see their own row under their own scope"

        assert count_as.(owner, other) == 0,
               "op.#{@table}: the owner can see ANOTHER user's row — the policy is not isolating"
      end
    end
  end

  describe "the policies exist and are FORCED on every secured table" do
    # ⛔ THE COMPLEMENT TO THE BEHAVIOURAL TESTS, and it is query-independent.
    # The cases above prove the policies WORK on `op.bookshelves`, where the
    # owner-sees-own / other-sees-none pair cannot both hold on a policy-free
    # table. They say nothing about the other three secured tables.
    #
    # ⚠️ `relforcerowsecurity` is the one most worth asserting, and the reason is
    # not obvious: **the table OWNER bypasses row-level security unless FORCE is
    # set.** This project does set it, but a future migration that recreated a
    # table without it would be invisible to every behavioural test that happens
    # to run as a non-owner — which is all of them here.
    test "all four carry row-level security, and it is forced" do
      %{rows: rows} =
        SQL.query!(
          Repo,
          """
          SELECT c.relname::text, c.relrowsecurity, c.relforcerowsecurity
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'op' AND c.relname = ANY($1)
          ORDER BY c.relname
          """,
          [@secured_tables]
        )

      # ⚠️ A floor on the population, or a renamed table silently empties the
      # set and this passes over nothing.
      assert length(rows) == length(@secured_tables),
             "expected #{length(@secured_tables)} secured tables, found #{length(rows)}: #{inspect(rows)}"

      for [name, enabled, forced] <- rows do
        assert enabled, "op.#{name} does not have row-level security ENABLED"

        assert forced,
               "op.#{name} has RLS enabled but NOT FORCED — its owner bypasses every policy, " <>
                 "and no behavioural test here would notice because none runs as the owner"
      end
    end

    test "each secured table has at least one policy" do
      %{rows: rows} =
        SQL.query!(
          Repo,
          """
          SELECT tablename::text, count(*) FROM pg_policies
          WHERE schemaname = 'op' AND tablename = ANY($1)
          GROUP BY tablename ORDER BY tablename
          """,
          [@secured_tables]
        )

      # ⚠️ The population floor is the whole assertion. A per-row `count >= 1`
      # would be unreachable: a `GROUP BY` row exists only when the count is at
      # least 1, so the only way a secured table fails here is by being ABSENT
      # from the result — which is what the length check catches.
      assert length(rows) == length(@secured_tables),
             "a secured table has NO policy at all — present: #{inspect(rows)}, " <>
               "expected all of #{inspect(@secured_tables)}"
    end
  end
end
