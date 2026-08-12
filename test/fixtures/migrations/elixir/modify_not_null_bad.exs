defmodule Core.Repo.Migrations.MakePageCountRequired do
  use Ecto.Migration

  def change do
    alter table(:books, prefix: "op") do
      modify :page_count, :integer, null: false
    end
  end
end
