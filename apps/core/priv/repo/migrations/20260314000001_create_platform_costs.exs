defmodule Core.Repo.Migrations.CreatePlatformCosts do
  use Ecto.Migration

  def change do
    create table(:platform_costs, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :category, :string, null: false
      add :service, :string, null: false
      add :description, :text
      add :amount_cents, :integer, null: false
      add :currency, :string, null: false, default: "USD"
      add :period_start, :utc_datetime_usec, null: false
      add :period_end, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create index(:platform_costs, [:category], prefix: "op")
    create index(:platform_costs, [:period_start, :period_end], prefix: "op")
    create unique_index(:platform_costs, [:service, :period_start, :period_end], prefix: "op")

    execute(
      """
      DO $$ BEGIN
        IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
          GRANT SELECT ON op.platform_costs TO stacks_dbt;
        END IF;
      END $$;
      """,
      """
      DO $$ BEGIN
        IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
          REVOKE SELECT ON op.platform_costs FROM stacks_dbt;
        END IF;
      END $$;
      """
    )
  end
end
