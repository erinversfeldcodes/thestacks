defmodule Stacks.ReleaseSeedGuardTest do
  @moduledoc """
      `Stacks.Release.seed_live/0` refuses to run on a node that is not a preview.

      ⛔ WHY THIS EXISTS. Its docstring said *"Prod-guarded by
      `STACKS_E2E_TEST_HELPERS`"* and the body called `run_seeds/0` with no guard
      of any kind. The claim had been there since the `eval` → `rpc` change; the
      guard had not. Anyone able to reach `bin/core rpc` on a production machine
      could have run the whole dev-fixture seed against the production database.

      ⚠️ THE DOCSTRING IS WHY NOBODY LOOKED. A reader checking whether this task
      was safe found a sentence saying it was, in the place they would look, and
      stopped. That is the failure mode this suite is really about: a guard
      asserted in prose is indistinguishable from a guard, right up to the moment
      it matters.

      ⚖️ Asserted on the REFUSAL rather than on the seeding. A test that seeds
      would need a preview-shaped node and would write fixtures into the test
      database to prove a point about production; the question here is only
      whether the gate is there and closed, which is answerable directly.
  """
  use ExUnit.Case, async: false

  @flag "STACKS_E2E_TEST_HELPERS"

  setup do
    original = System.get_env(@flag)

    on_exit(fn ->
      case original do
        nil -> System.delete_env(@flag)
        value -> System.put_env(@flag, value)
      end
    end)

    :ok
  end

  describe "seed_live/0 will not seed a node that is not a preview stack" do
    test "refuses when the flag is absent" do
      System.delete_env(@flag)

      error = assert_raise RuntimeError, fn -> Stacks.Release.seed_live() end

      # ⛔ The refusal must say WHICH condition failed and what the consequence
      # would have been. A bare "refused" sends the next operator looking for a
      # broken release rather than for an unset env.
      assert error.message =~ "STACKS_E2E_TEST_HELPERS"
      assert error.message =~ "not a preview stack"
    end

    test "refuses when the flag is set to something other than \"1\"" do
      # ⚠️ `"true"` specifically, because that is what the neighbouring
      # `ALLOW_SEEDS` gate accepts (`== "true"`). An operator who knows that gate
      # would reasonably try the same spelling here, and it must still refuse —
      # the plug this delegates to accepts only `"1"`.
      System.put_env(@flag, "true")

      assert_raise RuntimeError, fn -> Stacks.Release.seed_live() end
    end

    test "refuses when the flag is empty" do
      System.put_env(@flag, "")

      assert_raise RuntimeError, fn -> Stacks.Release.seed_live() end
    end

    # ⛔ ANTI-VACUITY, and without it every case above is satisfied by a function
    # that raises unconditionally — which would pass this suite while breaking
    # every preview deploy. This asserts the gate OPENS, and distinguishes "the
    # guard let me through" from "the guard refused me" by the error it does NOT
    # raise: seeding in the test environment fails for its own reasons (no seeds
    # file in the app dir under `MIX_ENV=test`), and that is a different failure
    # from the guard's.
    test "the guard opens when the flag is exactly \"1\" — it is a gate, not a wall" do
      System.put_env(@flag, "1")

      refusal =
        try do
          Stacks.Release.seed_live()
          nil
        rescue
          e -> Exception.message(e)
        end

      if is_binary(refusal) do
        refute refusal =~ "STACKS_E2E_TEST_HELPERS",
               "the guard refused a node whose flag is exactly \"1\": #{refusal}"

        refute refusal =~ "not a preview stack",
               "the guard refused a node whose flag is exactly \"1\": #{refusal}"
      end
    end
  end
end
