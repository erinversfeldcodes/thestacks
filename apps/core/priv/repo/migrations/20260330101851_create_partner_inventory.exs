defmodule Core.Repo.Migrations.CreatePartnerInventory do
  use Ecto.Migration

  def change do
    # Add third_space_id to partners so they can manage events for their space
    alter table(:partners, prefix: "op") do
      add :third_space_id,
          references(:third_spaces, type: :binary_id, prefix: "op", on_delete: :nilify_all)
    end

    create index(:partners, [:third_space_id], prefix: "op")

    create table(:partner_inventory, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :partner_id,
          references(:partners, type: :binary_id, prefix: "op", on_delete: :delete_all),
          null: false

      add :book_edition_id,
          references(:book_editions, type: :binary_id, prefix: "op", on_delete: :delete_all),
          null: false

      add :price_cents, :integer, null: false
      add :condition, :text, null: false
      add :quantity, :integer, null: false, default: 1
      add :synced_at, :utc_datetime_usec, null: false, default: fragment("NOW()")

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:partner_inventory, [:partner_id, :book_edition_id], prefix: "op")
    create index(:partner_inventory, [:book_edition_id], prefix: "op")

    create constraint(:partner_inventory, :price_cents_positive,
             check: "price_cents > 0",
             prefix: "op"
           )

    execute(
      """
      DO $$ BEGIN
        IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
          GRANT SELECT ON op.partner_inventory TO stacks_dbt;
        END IF;
      END $$;
      """,
      """
      DO $$ BEGIN
        IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
          REVOKE SELECT ON op.partner_inventory FROM stacks_dbt;
        END IF;
      END $$;
      """
    )
  end
end
