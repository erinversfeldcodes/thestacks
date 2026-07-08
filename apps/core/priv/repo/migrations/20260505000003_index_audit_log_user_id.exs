defmodule Core.Repo.Migrations.IndexAuditLogUserId do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create(
      index(:audit_log, [:user_id, :occurred_at],
        prefix: "audit",
        concurrently: true,
        name: "audit_log_user_id_occurred_at_idx"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:audit_log, [:user_id, :occurred_at],
        prefix: "audit",
        name: "audit_log_user_id_occurred_at_idx"
      ),
      concurrently: true
    )
  end
end
