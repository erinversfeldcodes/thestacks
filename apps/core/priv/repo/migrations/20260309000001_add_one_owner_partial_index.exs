defmodule Core.Repo.Migrations.AddOneOwnerPartialIndex do
  use Ecto.Migration

  def up do
    execute(
      "CREATE UNIQUE INDEX one_owner_per_platform ON op.users ((true)) WHERE role = 'owner'"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS op.one_owner_per_platform")
  end
end
