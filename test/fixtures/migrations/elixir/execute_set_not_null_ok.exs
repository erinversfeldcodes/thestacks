defmodule Core.Repo.Migrations.RawTightenHandleNotNullContract do
  use Ecto.Migration

  @breaking_ok "raw-execute NOT NULL tighten fixture: handle is written on every insert and backfilled; N-1 code no longer inserts null handles"

  def up do
    execute("ALTER TABLE op.users ALTER COLUMN handle SET NOT NULL")
  end

  def down do
    execute("ALTER TABLE op.users ALTER COLUMN handle DROP NOT NULL")
  end
end
