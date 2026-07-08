defmodule Core.Repo.Migrations.MakePageCountRequired do
  use Ecto.Migration

  # Tightens a column from nullable to NOT NULL without @breaking_ok.
  # N-1 code may insert rows with null page_count; this breaks them.
  def change do
    alter table(:books, prefix: "op") do
      modify :page_count, :integer, null: false
    end
  end
end
