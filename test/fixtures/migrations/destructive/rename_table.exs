defmodule Core.Repo.Migrations.Fixture.RenameTable do
  # Fixture: `ALTER TABLE ... RENAME TO`. Should trip `renaming-table`.
  use Ecto.Migration

  def change do
    execute("ALTER TABLE op.books RENAME TO works;")
  end
end
