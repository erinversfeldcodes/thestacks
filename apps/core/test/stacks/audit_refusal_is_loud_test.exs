defmodule Stacks.AuditRefusalIsLoudTest do
  @moduledoc """
      A refused audit read must reach the caller as an ERROR, never as an empty
      history.

      ⛔ THE DEFECT THIS EXISTS FOR. `Audit.list_for_user/2` used to map every
      error to an empty success — `_ -> 0` and `_ -> []`. On a deployed stack the
      runtime role held `INSERT` and no `SELECT` on `audit.audit_log`, so every
      read was refused and every reader was told their history was empty. The
      surface whose entire job is to say what was recorded about someone answered
      `200 {"total":0,"entries":[]}` with complete confidence. An absent key would
      have been honest; a zero is a claim.

      ⚠️ The code is already loud — both statements are `Repo.query!`. What was
      missing is anything that would NOTICE if that regressed, because the suite
      connects as a superuser and a superuser cannot be refused. So this drops to
      `stacks_app` and removes the grant inside the test's own transaction.

      ⚖️ Revoking inside the sandbox transaction is what makes this safe: Postgres
      DDL is transactional, so the grant is restored by the rollback that ends
      every test. Nothing here leaves the database changed.
  """
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Core.AppRole
  alias Core.Repo
  alias Ecto.Adapters.SQL
  alias Stacks.Audit

  @role "stacks_app"

  # ⛔ WHAT THESE CASES DO AND DO NOT GUARANTEE — measured, not assumed.
  #
  # `list_for_user/2` runs TWO statements: a COUNT and a page SELECT. Probed
  # 2026-11-07, one at a time and then together:
  #
  #   count swallows errors into 0   → 3 tests, 0 failures  (GREEN)
  #   page SELECT swallows into []   → 3 tests, 0 failures  (GREEN)
  #   BOTH swallow                   → 3 tests, 2 FAILURES
  #
  # So these cases prove **at least one of the two statements is loud**, not that
  # both are. Either one could regress to a silent empty and nothing here would
  # notice, because the other still raises and the raise is all these assertions
  # can see.
  #
  # ⚖️ Left as a stated limit rather than papered over. Closing it means asserting
  # per-statement — reading `total` and `entries` separately and demanding each
  # fail on its own — which needs a seam `list_for_user/2` does not currently
  # offer, since it returns one tuple built from both. That is a refactor of the
  # function under test to suit the test, and the honest trade is to record the
  # gap instead.
  #
  # ⚠️ The half that matters most IS covered: the measured production defect was
  # BOTH statements swallowing at once (the role held INSERT and no SELECT, so
  # every read was refused), and that is exactly the case these cases red on.

  describe "a refused read is an error, not an empty history" do
    test "list_for_user RAISES when the role cannot read the table" do
      user = insert(:user)

      # Remove the grant as the superuser the suite already is, then drop to the
      # least-privilege role. Both inside the sandbox transaction, so the rollback
      # restores the grant.
      SQL.query!(Repo, "REVOKE SELECT ON audit.audit_log FROM #{@role}", [])

      assert_raise Postgrex.Error, fn ->
        AppRole.as_app_role(fn ->
          Audit.list_for_user(user.id)
        end)
      end
    end

    test "the refusal is a permission error, so the cause is legible" do
      user = insert(:user)
      SQL.query!(Repo, "REVOKE SELECT ON audit.audit_log FROM #{@role}", [])

      error =
        assert_raise Postgrex.Error, fn ->
          AppRole.as_app_role(fn -> Audit.list_for_user(user.id) end)
        end

      # ⛔ Asserting the CODE, not the message. A reader of a failure needs to know
      # it was a privilege problem and not a malformed query, and the message text
      # is localisable where the SQLSTATE is not.
      assert error.postgres.code == :insufficient_privilege,
             "expected a privilege refusal, got #{inspect(error.postgres.code)}"
    end

    test "with the grant in place the same call succeeds, so the refusal is the variable" do
      # ⛔ ANTI-VACUITY. Without this, a `list_for_user/2` that raised
      # unconditionally — a typo'd table, a broken decoder — would satisfy both
      # cases above and look like a working guarantee.
      user = insert(:user)

      # ⛔ ASSERT THE SHAPE IT RETURNS, not one it cannot. An earlier version here
      # was `refute match?({:error, _}, result)` — and `list_for_user/2` returns a
      # four-tuple and RAISES on failure, so it can never produce `{:error, _}`.
      # The case written to close the "everything raises" degenerate asserted a
      # shape the function does not have, and therefore closed nothing.
      {entries, total, page, per_page} =
        AppRole.as_app_role(fn ->
          Audit.list_for_user(user.id)
        end)

      assert is_list(entries)
      assert is_integer(total) and total >= 0
      assert page == 1
      assert is_integer(per_page) and per_page > 0
    end
  end
end
