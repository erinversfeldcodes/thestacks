defmodule Core.Repo.Migrations.AddBookSlug do
  use Ecto.Migration

  def change do
    alter table(:books, prefix: "op") do
      add :slug, :text
    end
  end
end
