defmodule Core.Repo.Migrations.UpdateObanToV14 do
  use Ecto.Migration

  # Oban 2.23 requires migration version 14 (previously created at v12 in
  # 20260305000019_create_oban_tables.exs). Bump forward; `down` returns to the
  # last known-good v12 rather than fully tearing the tables down.
  def up do
    Oban.Migration.up(version: 14)
  end

  def down do
    Oban.Migration.down(version: 12)
  end
end
