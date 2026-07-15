defmodule Core.Repo.Migrations.Fixture.DslUniqueIndex do
  # #219 regression fixture: a hazardous index build expressed with the Ecto
  # DSL rather than raw execute() SQL. `create unique_index(..., concurrently:
  # false)` takes a write-blocking lock on the table for the whole build.
  # Before #219 squawk never saw this because it only linted execute() strings;
  # now the shared extractor translates the DSL to `CREATE UNIQUE INDEX ...`
  # (no CONCURRENTLY), which must trip `require-concurrent-index-creation`.
  use Ecto.Migration

  def change do
    create unique_index(:users, [:handle], prefix: "op", concurrently: false)
  end
end
