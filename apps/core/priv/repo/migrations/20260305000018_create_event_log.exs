defmodule Core.Repo.Migrations.CreateEventLog do
  use Ecto.Migration

  def up do
    create table(:event_log, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event_type, :text, null: false
      add :aggregate_type, :text, null: false
      add :aggregate_id, :binary_id, null: false
      add :schema_version, :integer, null: false, default: 1
      add :payload, :map, null: false
      add :metadata, :map
      add :occurred_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :published_at, :utc_datetime_usec
    end

    execute(
      "CREATE INDEX idx_event_log_type_agg ON op.event_log (event_type, aggregate_id, occurred_at DESC)"
    )
  end

  def down do
    drop table(:event_log, prefix: "op")
  end
end
