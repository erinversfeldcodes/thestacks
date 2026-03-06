defmodule Core.Repo.Migrations.CreateThirdSpaces do
  use Ecto.Migration

  def up do
    execute("""
    DO $$ BEGIN
      CREATE TYPE op.space_type AS ENUM ('reading_group', 'cafe', 'bookshop', 'festival', 'market');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    create table(:third_spaces, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :type, :space_type, null: false
      add :city, :text
      add :country_code, :text, default: "ZA"
      add :instagram_url, :text
      add :website_url, :text
      add :description, :text
      add :discovered_via, :text
      add :verified, :boolean, default: false
      add :last_active_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end
  end

  def down do
    drop table(:third_spaces, prefix: "op")
    execute("DROP TYPE IF EXISTS op.space_type")
  end
end
