defmodule Core.Repo.Migrations.RawTightenHandleNotNull do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE op.users ALTER COLUMN handle SET NOT NULL")
  end

  def down do
    execute("ALTER TABLE op.users ALTER COLUMN handle DROP NOT NULL")
  end
end
