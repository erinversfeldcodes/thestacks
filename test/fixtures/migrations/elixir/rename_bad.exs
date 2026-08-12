defmodule Core.Repo.Migrations.RenameCoverImageUrl do
  use Ecto.Migration

  def change do
    rename table(:books, prefix: "op"),
           :cover_image_url,
           to: :cover_url
  end
end
