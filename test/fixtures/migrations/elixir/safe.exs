defmodule Core.Repo.Migrations.AddBookSlug do
  use Ecto.Migration

  # Purely additive: nullable column, no default, no destructive ops.
  # No @breaking_ok required.
  def change do
    alter table(:books, prefix: "op") do
      add :slug, :text
    end
  end
end
