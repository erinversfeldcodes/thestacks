defmodule Core.Repo.Migrations.DropCoverImageUrlContract do
  use Ecto.Migration

  # Contract phase: the application stopped reading/writing this column in
  # commit abc123. Safe to drop.
  @breaking_ok "cover_image_url superseded by book_editions.cover_url in commit abc123; N-1 code no longer references it"

  def change do
    alter table(:books, prefix: "op") do
      remove :cover_image_url
    end
  end
end
