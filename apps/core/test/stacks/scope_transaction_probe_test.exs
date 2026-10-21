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
