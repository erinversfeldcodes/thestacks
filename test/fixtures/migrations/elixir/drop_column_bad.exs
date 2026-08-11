defmodule Core.Repo.Migrations.DropCoverImageUrl do
  use Ecto.Migration

  def change do
    alter table(:books, prefix: "op") do
      remove :cover_image_url
    end
  end
end
