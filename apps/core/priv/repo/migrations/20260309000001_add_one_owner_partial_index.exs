defmodule Core.Repo.Migrations.AddOneOwnerPartialIndex do
  use Ecto.Migration

  # Prevents a race condition where two concurrent registrations both read
  # a user count of 0 and both attempt to claim the owner role.
  # The partial index allows at most one row with role = 'owner'.

  def up do
    execute(
      "CREATE UNIQUE INDEX one_owner_per_platform ON op.users ((true)) WHERE role = 'owner'"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS op.one_owner_per_platform")
  end
end
