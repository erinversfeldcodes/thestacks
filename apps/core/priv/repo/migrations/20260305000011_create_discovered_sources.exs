defmodule Core.Repo.Migrations.CreateDiscoveredSources do
  use Ecto.Migration

  def up do
    execute("""
    DO $$ BEGIN
      CREATE TYPE op.source_type AS ENUM ('bookshop', 'review_site', 'community', 'event_source');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    execute("""
    DO $$ BEGIN
      CREATE TYPE op.source_status AS ENUM ('pending_review', 'approved', 'dismissed');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    create table(:discovered_sources, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :type, :source_type, null: false
      add :url, :text, null: false
      add :confidence, :float
      add :discovered_via, :text
      add :discovered_at, :utc_datetime_usec, null: false
      add :status, :source_status, null: false
      add :approved_at, :utc_datetime_usec
      add :config_generated, :map

      timestamps(type: :utc_datetime_usec)
    end
  end

  def down do
    drop table(:discovered_sources, prefix: "op")
    execute("DROP TYPE IF EXISTS op.source_status")
    execute("DROP TYPE IF EXISTS op.source_type")
  end
end
