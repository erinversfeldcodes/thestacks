defmodule Core.Repo.Migrations.Fixture.SafeAddColumn do
  # Fixture: purely additive — nullable column, no default. Squawk should pass.
  use Ecto.Migration

  def change do
    execute("ALTER TABLE op.books ADD COLUMN slug text;")
  end
end
