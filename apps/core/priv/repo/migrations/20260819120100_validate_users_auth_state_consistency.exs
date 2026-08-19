defmodule Core.Repo.Migrations.ValidateUsersAuthStateConsistency do
  @moduledoc """
      Validates the two `op.users` auth CHECKs added `NOT VALID` in the previous
      migration, so they cover the rows that were already there and not only the
      rows written from now on.

      Its own migration because `VALIDATE CONSTRAINT` only takes the gentle
      SHARE UPDATE EXCLUSIVE lock when it runs in a DIFFERENT transaction from
      the `ADD` — validating in the same transaction holds the `ADD`'s ACCESS
      EXCLUSIVE lock across the whole scan, which is the outage `NOT VALID`
      exists to avoid.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("ALTER TABLE op.users VALIDATE CONSTRAINT users_password_reset_pair_consistent")

    execute("ALTER TABLE op.users VALIDATE CONSTRAINT users_login_lockout_state_consistent")
  end

  def down, do: :ok
end
