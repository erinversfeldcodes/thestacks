defmodule Core.Repo.Migrations.FixEventLogMetadataNotNull do
  use Ecto.Migration

  def up do
    execute("UPDATE op.event_log SET metadata = '{}' WHERE metadata IS NULL")

    alter table(:event_log, prefix: "op") do
      modify :metadata, :map, null: false, default: fragment("'{}'::jsonb")
    end
  end

  def down do
    alter table(:event_log, prefix: "op") do
      modify :metadata, :map, null: true, default: nil
    end
  end
end
