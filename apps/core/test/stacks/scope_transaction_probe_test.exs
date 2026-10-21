defmodule Stacks.ScopeTransactionProbeTest do
  @moduledoc """
      The two facts `Stacks.Scope` uses to decide whether it must restore the
      previous row-level-security scope by hand.

      ⛔ READ THE SPLIT BELOW BEFORE TRUSTING THIS FILE. The two end-to-end
      cases assert a true and valuable invariant — a scope does not outlive its
      block — but **neither can fail on the bug they describe**. Under the
      sandbox `sandboxed?/0` is always true, so `must_restore?/0`
      short-circuits and both pass under the OLD pool-keyed implementation too.
      They are regression guards against someone deleting the restore, not
      evidence that the two-term condition is right.
      
      That is the same structure as the defect itself: the suite takes the
      restoring branch and production took the leaking one, so a test written
      in the suite cannot distinguish them. The DECISION is therefore pinned
      separately, as a truth table over `must_restore?/2`, where the
      `{false, true}` row is the production leak case — and that row is the
      only part of this reachable from inside the sandbox. End-to-end
      behaviour off the sandbox was observed on the deployed preview drive.

      ⚠️ And the table alone was not enough either, which is the second half
      of the split. The old condition did not get `or` wrong — it omitted the
      second argument — so a truth table over `must_restore?/2` cannot see the
      actual regression: reverting the private combiner to `sandboxed?/0` alone
      leaves all four rows AND both end-to-end cases green. The inputs are
      therefore pinned separately via `restore_inputs/0`, leaving a pattern
      match as the only unpinned step. That is as far down as this is worth
      taking; past it the instrument is a deployed drive, not more scaffolding.

      ⛔ Why this is a test and not a comment: the decision rests on whether a
      COMMIT will intervene to revert `SET LOCAL`, and getting it wrong is
      invisible. An earlier version keyed on the pool instead, on the premise
      that a real connection always commits — false whenever `with_user/2` is
      called inside a transaction it did not open, which happens on the deploy
      path. The result was that the test suite exercised the restoring branch
      and PRODUCTION exercised the leaking one, so no test could observe the
      production behaviour at all.
  """
  use Core.DataCase, async: false

  alias Core.Repo

  test "the sandbox's held transaction is NOT visible to in_transaction?/0" do
    # ⚠️ Measured, and it is the opposite of what one would assume. The sandbox
    # holds the connection inside a transaction, which is why `Repo.transaction`
    # becomes a SAVEPOINT in tests — but it holds it at the CONNECTION level,
    # outside Ecto's per-process transaction tracking, so `in_transaction?/0`
    # reports false at the top of a test.
    #
    # That is why `Stacks.Scope` cannot use `in_transaction?/0` alone: it would
    # skip the restore in exactly the environment that needs it most, and the
    # scope would leak across a test boundary.
    refute Repo.in_transaction?(),
           "if this ever becomes true, Stacks.Scope's `sandboxed?() or in_transaction?()` " <>
             "condition can be simplified to the second term alone"
  end

  test "being inside a transaction is detectable, which is what must_restore?/0 reads" do
    Repo.transaction(fn ->
      assert Repo.in_transaction?(),
             "a nested transaction must be detectable — this is the signal that our own " <>
               "transaction will be a savepoint, and that releasing it will NOT revert SET LOCAL"
    end)
  end

  describe "must_restore?/2 — the decision, which the sandbox CAN pin" do
    test "the production leak case is {false, true} and demands a restore" do
      # ⛔ The row that matters and the one no end-to-end assertion here can
      # reach: not sandboxed, but nested inside a transaction somebody else
      # opened — so our own is a savepoint, releasing it does not revert
      # `SET LOCAL`, and nothing else will. This is the quadrant the previous
      # pool-keyed condition got wrong in production.
      assert Stacks.Scope.must_restore?(false, true)
    end

    test "the ordinary request boundary is {false, false} and must NOT restore" do
      # ⚠️ The cost half. A restore here is two extra statements on every
      # scoped read, which pushed two N+1 bounds over their limits.
      refute Stacks.Scope.must_restore?(false, false)
    end

    test "the sandbox demands a restore whether or not it is also nested" do
      # Both terms are load-bearing: `in_transaction?/0` is FALSE at the top of
      # a sandboxed test, because the sandbox's BEGIN happens at checkout
      # outside Ecto's per-process tracking. Without the first term the
      # restore would be skipped in the one environment where no commit ever
      # arrives.
      assert Stacks.Scope.must_restore?(true, false)
      assert Stacks.Scope.must_restore?(true, true)
    end
  end

  describe "restore_inputs/0 — the facts fed to the decision" do
    # ⛔ WHY THIS BLOCK EXISTS, and it is the sharpest thing in this file.
    # The truth table above pins the COMBINATION, and the old bug was not in
    # the combination: it omitted the second argument entirely. Revert the
    # private combiner to `sandboxed?()` alone and every test above stays
    # green — the four rows because `must_restore?/2` is untouched, the two
    # end-to-end cases because `sandboxed?/0` is always true here. The
    # regression would come back under a fully green file.
    #
    # Pinning the inputs separately closes that: the only step left unpinned
    # is a pattern match destructuring the tuple.

    test "at the top of a sandboxed test the inputs are {true, false}" do
      # Which is the quadrant that makes the suite unable to see the bug: the
      # first term alone is already enough to demand a restore here.
      assert Stacks.Scope.restore_inputs() == {true, false}
    end

    test "inside a caller-owned transaction the inputs are {true, true}" do
      Repo.transaction(fn ->
        assert Stacks.Scope.restore_inputs() == {true, true},
               "the second term must flip inside a transaction — if it does not, " <>
                 "`in_transaction?/0` is not reporting what the decision needs"
      end)
    end

    test "⚠️ the second term is the one the suite cannot vary to false-with-production-shape" do
      # The honest statement of the limit, asserted rather than left in prose:
      # `sandboxed?/0` is pinned true for the whole suite, so {false, _} — every
      # production quadrant — is unreachable from here by construction. The
      # table covers it as data; the behaviour is covered by the deployed drive.
      {sandboxed?, _} = Stacks.Scope.restore_inputs()

      assert sandboxed?,
             "if this is ever false the suite is no longer sandboxed, and the end-to-end " <>
               "cases in this file would finally be able to fail on the production bug — " <>
               "at which point they, not the truth table, become the primary evidence"
    end

    test "⛔ the private combiner reads BOTH inputs — the one thing only the source can show" do
      # ⛔ MEASURED, and it is why this assertion is structural rather than
      # behavioural. Pinning the inputs and pinning the combination still does
      # NOT catch the regression that shipped: replace the private
      # `must_restore?/0` with `sandboxed?()` alone and all 31 tests in this
      # file stay GREEN — the four table rows because `must_restore?/2` is
      # untouched, the end-to-end cases and the input tests above because
      # `sandboxed?/0` is true here.
      #
      # The reason is arithmetic, not oversight: inside the sandbox
      # `sandboxed?()` is true, so `sandboxed?() or anything` IS `sandboxed?()`.
      # The composition is unobservable in this environment for EVERY possible
      # second term, so no behavioural assertion written here can distinguish
      # the two implementations. Decomposing further just moves the hole.
      #
      # What remains observable is the source: that the composed decision is
      # expressed in terms of `restore_inputs/0` rather than one term of it.
      # That is a weaker claim than behaviour and is stated as such — it catches
      # the regression by shape, and it is the only instrument in the suite that
      # catches it at all. The behavioural evidence is the deployed drive.
      source = File.read!("lib/stacks/scope.ex")

      [combiner] =
        Regex.run(~r/defp must_restore\? do\n(.*?)\n  end/s, source, capture: :all_but_first)

      assert combiner =~ "restore_inputs()",
             "the composed decision no longer reads restore_inputs/0, so it may be using one " <>
               "term where two are needed — the exact regression that leaked a scope in " <>
               "production, and one that every behavioural test in this file passes under"

      assert combiner =~ "must_restore?(sandboxed?, in_transaction?)",
             "the composed decision no longer passes BOTH inputs to must_restore?/2"
    end
  end

  test "a scope does not outlive its own block, even nested inside a caller's transaction" do
    # ⚠️ No row needed: `with_user/2` sets a scope, it does not verify the
    # user exists, and what is under test is whether the setting survives.
    user_id = Ecto.UUID.generate()

    # ⛔ The invariant the pool-keyed condition broke in production. `apply_plan`
    # in the data-correction path opens a transaction and then calls
    # `Scope.with_user/2` once per owner inside it; if the scope survives the
    # inner block, the rest of the outer transaction runs scoped to whichever
    # owner happened to be last, with nothing in the process state recording it.
    Repo.transaction(fn ->
      Stacks.Scope.with_user(user_id, fn -> :ok end)

      assert Stacks.Scope.current() == nil,
             "the scope outlived its block inside a caller-owned transaction — releasing a " <>
               "savepoint does not revert SET LOCAL, so it must be restored explicitly"
    end)
  end

  test "a scope does not outlive its own block at the outermost level either" do
    user_id = Ecto.UUID.generate()
    Stacks.Scope.with_user(user_id, fn -> :ok end)

    assert Stacks.Scope.current() == nil
  end
end
