defmodule Core.Repo.Migrations.Fixture.RenameTable do
  use Ecto.Migration

  def change do
    execute("ALTER TABLE op.books RENAME TO works;")
  end
end
