defmodule Stacks.ScopeTransactionProbeTest do
  @moduledoc """
      The two facts `Stacks.Scope` uses to decide whether it must restore the
      previous row-level-security scope by hand.

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

  test "a transaction opened inside another IS visible, which is the production leak case" do
    Repo.transaction(fn ->
      assert Repo.in_transaction?(),
             "a nested transaction must be detectable — this is the signal that our own " <>
               "transaction will be a savepoint, and that releasing it will NOT revert SET LOCAL"
    end)
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
