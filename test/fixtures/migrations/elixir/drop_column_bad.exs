defmodule Core.Repo.Migrations.DropCoverImageUrl do
  use Ecto.Migration

  # No @breaking_ok annotation — linter should refuse this.
  def change do
    alter table(:books, prefix: "op") do
      remove :cover_image_url
    end
  end
end
