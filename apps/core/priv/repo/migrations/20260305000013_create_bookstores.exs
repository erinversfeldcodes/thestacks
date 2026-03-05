defmodule Core.Repo.Migrations.CreateBookstores do
  use Ecto.Migration

  def change do
    create table(:bookstores, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :website_url, :text
      add :search_template, :text
      add :has_physical, :boolean, default: false
      add :country_code, :text, default: "ZA"
      add :scraper_module, :text

      timestamps(type: :utc_datetime_usec)
    end
  end
end
