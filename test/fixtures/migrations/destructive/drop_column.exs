defmodule Core.Repo.Migrations.Fixture.DropColumn do
  # Fixture: destructive `ALTER TABLE ... DROP COLUMN`. Extracted SQL should
  # trip squawk's `ban-drop-column` rule once Phase 2 enables it.
  use Ecto.Migration

  def change do
    execute("ALTER TABLE op.books DROP COLUMN cover_image_url;")
  end
end
