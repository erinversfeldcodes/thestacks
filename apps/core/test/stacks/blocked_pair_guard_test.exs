defmodule Stacks.BlockedPairGuardTest do
  @moduledoc """
  The `op.blocked_pair/2` enumeration guard.

  `op.blocked_pair(a, b)` answers the SYMMETRIC "is either user blocking the
  other", for the block-aware reads (search exclusion, the group feed). It is
  SECURITY DEFINER so it can see both parties' block rows, which a scoped
  subquery cannot — but a definer that will answer about any pair is an
  enumeration oracle. The guard closes that for a USER-SCOPED caller: it refuses
  a question about two OTHER people when a real user scope is set, so a scoped
  caller can only ask about pairs it belongs to.

  ⚠️ It deliberately does NOT refuse an anonymous or unscoped caller: the
  public-profile read asks this question with no viewer, and refusing there
  would turn a privacy check into a 5xx on exactly those paths. Declaring the
  anonymous scope needs no privilege, so a COMPROMISED runtime role could
  declare itself anonymous and enumerate the block graph. That residual is
  inherent to a compromised role — a larger breach than block-graph enumeration,
  and not closable at the database — while every legitimate application path
  already passes the viewer as one argument (`Accounts.exclude_blocked/2`), so no
  real caller enumerates. These tests pin both halves: the guard fires for a
  scoped cross-user question, and the anonymous fall-through is intentional.
  """
  use Core.DataCase, async: false

  alias Core.Repo

  @a "11111111-1111-1111-1111-111111111111"
  @b "22222222-2222-2222-2222-222222222222"
  @c "33333333-3333-3333-3333-333333333333"

  # Sets the scope GUC for the surrounding sandbox transaction, then asks the
  # guarded question on the same connection. `set_config(…, true)` is
  # transaction-local, so the sandbox rolls it back between tests.
  defp ask(scope, a, b) do
    Repo.query!("SELECT set_config('app.current_user_id', $1, true)", [scope])
    Repo.query("SELECT op.blocked_pair($1::uuid, $2::uuid)", [a, b])
  end

  test "a user-scoped caller asking about two OTHER users is refused" do
    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             ask(@a, @b, @c)
  end

  test "a user-scoped caller may ask when it is one of the two" do
    assert {:ok, %{rows: [[answer]]}} = ask(@a, @a, @b)
    assert is_boolean(answer)
  end

  test "an anonymous caller falls through — the accepted, documented residual" do
    assert {:ok, %{rows: [[answer]]}} = ask("anonymous", @b, @c)
    assert is_boolean(answer)
  end
end
