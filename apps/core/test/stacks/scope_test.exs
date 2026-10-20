defmodule Stacks.ScopeTest do
  @moduledoc """
      `Stacks.Scope` is the only thing that sets the row-level-security scope,
      so these assert the mechanism rather than the policies.

      ⛔ **What this file cannot prove, stated up front.** The test environment
      connects as `postgres`, which is `rolsuper = true`, and **superusers
      bypass row-level security entirely** — so nothing here can show that a
      policy refuses anything. A green run of this file says the scope is set
      and unset correctly; it says nothing about enforcement. Enforcement is
      proven against `stacks_app`, a non-superuser role, and that evidence lives
      in the issue's notes and the `:deployed_only` suite. A test that implied
      otherwise would be the exact instrument-that-cannot-go-red this whole
      change exists to remove.

      ⚠️ **A second thing the sandbox hides, found while writing this file.**
      ExUnit's sandbox wraps each test in a transaction, and `SET LOCAL` binds
      to the OUTERMOST transaction — so inside a boxed test `with_user/2`'s
      transaction is a savepoint, the scope does not revert when it releases,
      and a bare `SET LOCAL` outside any explicit transaction *does* take
      effect. Both are the opposite of production behaviour. The two tests that
      assert the mechanism therefore run through
      `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`; sandboxed, they would report
      the reverse of the truth.
  """

  use Core.DataCase, async: false

  alias Core.Repo
  alias Ecto.Adapters.SQL.Sandbox
  alias Stacks.Scope

  @user_a "11111111-1111-1111-1111-111111111111"
  @user_b "22222222-2222-2222-2222-222222222222"

  defp guc do
    %{rows: [[value]]} = Repo.query!("SELECT current_setting('app.current_user_id', true)", [])
    value
  end

  describe "with_user/2" do
    test "the scope is readable inside the function" do
      assert Scope.with_user(@user_a, fn -> guc() end) == @user_a
    end

    test "it returns the function's value unwrapped, not an {:ok, _} tuple" do
      # A caller reads the same as it did before the scope existed, which is
      # what keeps this from rippling through every context's return shape.
      assert Scope.with_user(@user_a, fn -> :whatever end) == :whatever
      assert Scope.with_user(@user_a, fn -> {:error, :nope} end) == {:error, :nope}
    end

    test "⛔ the scope does NOT survive the call" do
      # The leak this mechanism is chosen to prevent. `SET LOCAL` reverts when
      # the transaction ends; a session-level `SET` would not, and on a pooled
      # connection that is one reader seeing another reader's rows.
      #
      # ⛔ UNBOXED, and that is the finding rather than a workaround. The ExUnit
      # sandbox wraps each test in its own transaction, so `with_user/2`'s
      # `Repo.transaction` becomes a SAVEPOINT inside it — and `SET LOCAL`
      # binds to the OUTERMOST transaction, which in a sandboxed test is the
      # sandbox's and does not end until the test does. Sandboxed, this
      # assertion fails while production behaviour is correct: the no-leak
      # property is structurally unobservable in a boxed test, so proving it
      # requires a real connection.
      Sandbox.unboxed_run(Repo, fn ->
        Scope.with_user(@user_a, fn -> :ok end)

        assert Scope.current() == nil,
               "the scope survived the call, so the next piece of work on this connection " <>
                 "would run as #{@user_a}"
      end)
    end

    test "⚠️ it survives neither a raise nor a throw" do
      assert_raise RuntimeError, fn -> Scope.with_user(@user_a, fn -> raise "boom" end) end

      assert Scope.current() == nil,
             "a raising operation left the connection scoped to #{@user_a}"
    end

    test "Scope.current/0 reads the live setting inside a scope" do
      assert Scope.with_user(@user_b, fn -> Scope.current() end) == @user_b
    end
  end

  describe "nesting" do
    test "the same user nested is a pass-through, not a second transaction" do
      result =
        Scope.with_user(@user_a, fn ->
          Scope.with_user(@user_a, fn -> guc() end)
        end)

      assert result == @user_a
    end

    test "⛔ a DIFFERENT user nested is refused" do
      # Not a nesting case but a correctness one: two users in one logical
      # operation means something is acting on behalf of the wrong person, and
      # the database would serve whichever scope was outermost. Louder here
      # than as a row that should not exist.
      assert_raise ArgumentError, ~r/cannot re-scope/, fn ->
        Scope.with_user(@user_a, fn ->
          Scope.with_user(@user_b, fn -> :unreachable end)
        end)
      end
    end

    test "the outer scope survives a refused inner re-scope" do
      # The refusal must not corrupt the scope it refused to change.
      assert_raise ArgumentError, fn ->
        Scope.with_user(@user_a, fn ->
          Scope.with_user(@user_b, fn -> :unreachable end)
        end)
      end

      assert Scope.current() == nil
    end
  end

  describe "⛔ the mechanism, not the wrapper" do
    test "SET LOCAL outside a transaction does NOT take — which is why this wrapper exists" do
      # ⛔ The measurement the whole design rests on, asserted rather than
      # trusted to a comment. Postgres emits a WARNING, not an error, so an
      # implementation that set the scope without a transaction would look
      # wired, enforce nothing, and pass every unit test that did not check it.
      #
      # ⚠️ Must be UNBOXED for the same reason as above, and the reason is
      # sharper here: inside the sandbox there IS already a transaction, so a
      # bare `SET LOCAL` takes effect and this assertion would fail — telling
      # you the opposite of the truth about how the code behaves in production.
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("SET LOCAL app.current_user_id = '#{@user_a}'")

        assert Scope.current() == nil,
               "SET LOCAL took effect outside a transaction on this Postgres — if that is ever " <>
                 "true the transaction requirement in Stacks.Scope can be revisited, but the " <>
                 "measured behaviour is a warning and a no-op"
      end)
    end

    test "set_config with the local flag inside a transaction DOES take" do
      # The positive half of the same measurement: the form `with_user/2`
      # actually uses works where the bare `SET LOCAL` above does not.
      result =
        Repo.transaction(fn ->
          Repo.query!("SELECT set_config('app.current_user_id', $1, true)", [@user_b])
          guc()
        end)

      assert {:ok, @user_b} = result
    end
  end

  describe "⛔ the scope value is normalised, not trusted" do
    test "a RAW 16-byte uuid is accepted and canonicalised" do
      # ⛔ Found by the seed, not by a test: `Seeds.uuid/1` and
      # `Ecto.UUID.dump/1` both yield the 16-byte form, and `is_binary/1`
      # cannot tell it from the string form. Passed through untouched it failed
      # at the database with `invalid byte sequence for encoding "UTF8"` — and
      # that was the LUCKY case. Sixteen bytes that happened to be valid UTF-8
      # would have been accepted silently, setting a scope matching no user, so
      # every query in the operation would return nothing while reporting
      # success.
      {:ok, raw} = Ecto.UUID.dump(@user_a)

      assert Scope.with_user(raw, fn -> guc() end) == @user_a,
             "a raw 16-byte uuid did not reach the database as its canonical string form"
    end

    test "⚠️ a non-uuid is REFUSED rather than set" do
      # A scope that is not a uuid would be set without complaint by
      # `set_config` and then match no row, which is the silent-empty-result
      # failure this whole mechanism exists to remove.
      assert_raise ArgumentError, ~r/must be a UUID/, fn ->
        Scope.with_user("not-a-uuid", fn -> :unreachable end)
      end
    end
  end

  describe "what the test environment cannot show" do
    test "⚠️ this suite's role BYPASSES row-level security, and says so" do
      # ⛔ An explicit assertion rather than a comment, because the alternative
      # is somebody later reading a green run of this file as evidence that
      # enforcement works. If the test role ever stops being a superuser this
      # fails, and whoever sees it should then move the enforcement proofs here
      # from the deployed suite — which would be an improvement, not a break.
      %{rows: [[super?]]} =
        Repo.query!("SELECT rolsuper FROM pg_roles WHERE rolname = current_user", [])

      assert super?,
             "the test role is no longer a superuser, so row-level security now applies in " <>
               "`MIX_ENV=test`. The enforcement assertions currently proven only against " <>
               "stacks_app can and should move into this suite."
    end
  end
end
