defmodule Core.Repo.Migrations.CreateAuthors do
  use Ecto.Migration

  def change do
    create table(:authors, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :website_url, :text
      add :rss_feed_url, :text
      add :open_library_id, :text
      add :bio, :text

      timestamps(type: :utc_datetime_usec)
    end
  end
end
