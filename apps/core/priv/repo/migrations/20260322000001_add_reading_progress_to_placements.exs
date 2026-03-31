defmodule Core.Repo.Migrations.AddReadingProgressToPlacements do
  use Ecto.Migration

  def up do
    alter table(:bookshelf_placements, prefix: "op") do
      add_if_not_exists :reading_status, :text, default: "to_read", null: false
      add_if_not_exists :current_page, :integer
      add_if_not_exists :started_at, :utc_datetime_usec
      add_if_not_exists :finished_at, :utc_datetime_usec
    end

    execute("""
    DO $body$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_namespace n ON n.oid = c.connamespace
        WHERE n.nspname = 'op' AND c.conname = 'reading_status_valid'
      ) THEN
        ALTER TABLE op.bookshelf_placements
          ADD CONSTRAINT reading_status_valid
          CHECK (reading_status IN ('to_read', 'reading', 'completed', 'abandoned'));
      END IF;
    END $body$;
    """)

    execute("""
    DO $body$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_namespace n ON n.oid = c.connamespace
        WHERE n.nspname = 'op' AND c.conname = 'current_page_non_negative'
      ) THEN
        ALTER TABLE op.bookshelf_placements
          ADD CONSTRAINT current_page_non_negative CHECK (current_page >= 0);
      END IF;
    END $body$;
    """)
  end

  def down do
    execute("ALTER TABLE op.bookshelf_placements DROP CONSTRAINT IF EXISTS reading_status_valid")

    execute(
      "ALTER TABLE op.bookshelf_placements DROP CONSTRAINT IF EXISTS current_page_non_negative"
    )

    alter table(:bookshelf_placements, prefix: "op") do
      remove_if_exists :reading_status, :text
      remove_if_exists :current_page, :integer
      remove_if_exists :started_at, :utc_datetime_usec
      remove_if_exists :finished_at, :utc_datetime_usec
    end
  end
end
