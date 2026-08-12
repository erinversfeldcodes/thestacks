defmodule Core.Repo.Migrations.CreateAuditLog do
  use Ecto.Migration

  def change do
    create table(:audit_log, prefix: "audit", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id
      add :action, :text, null: false
      add :resource_type, :text, null: false
      add :resource_id, :binary_id
      add :metadata, :map
      add :ip_address, :text
      add :occurred_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end
  end
end
