defmodule Core.Repo.Migrations.CreateShelves do
  use Ecto.Migration

  def up do
    create table(:shelves, primary_key: false, prefix: "op") do
      add :id, :binary_id, primary_key: true, null: false, default: fragment("gen_random_uuid()")

      add :bookshelf_id,
          references(:bookshelves, type: :binary_id, on_delete: :delete_all, prefix: "op"),
          null: false

      add :position, :integer, null: false, default: 0
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:shelves, [:bookshelf_id, :position], prefix: "op")

    execute(
      """
      DO $$ BEGIN
        IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
          GRANT SELECT ON op.shelves TO stacks_dbt;
        END IF;
      END $$;
      """,
      """
      DO $$ BEGIN
        IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
          REVOKE SELECT ON op.shelves FROM stacks_dbt;
        END IF;
      END $$;
      """
    )

    execute("""
    INSERT INTO op.shelves (id, bookshelf_id, position, created_at)
    SELECT gen_random_uuid(), id, 0, now()
    FROM op.bookshelves
    """)

    alter table(:bookshelf_placements, prefix: "op") do
      add :shelf_id,
          references(:shelves, type: :binary_id, on_delete: :nilify_all, prefix: "op"),
          null: true
    end

    execute("""
    UPDATE op.bookshelf_placements p
    SET shelf_id = s.id
    FROM op.shelves s
    WHERE s.bookshelf_id = p.bookshelf_id
    """)

    execute("ALTER TABLE op.bookshelf_placements ALTER COLUMN shelf_id SET NOT NULL")
  end

  def down do
    alter table(:bookshelf_placements, prefix: "op") do
      remove :shelf_id
    end

    drop_if_exists unique_index(:shelves, [:bookshelf_id, :position], prefix: "op")
    drop table(:shelves, prefix: "op")
  end
end
