defmodule Core.Repo.Migrations.MakeStoragePathNullable do
  use Ecto.Migration

  # The staging.stg_uploaded_images view may select storage_path on an existing
  # deployment, causing PostgreSQL to refuse the ALTER. We drop the view first if
  # it exists. Recreation is dbt's responsibility — running this migration on a
  # fresh Neon branch where the staging schema doesn't yet exist is safe because
  # DROP VIEW IF EXISTS is a no-op when the schema is absent.

  def up do
    execute("DROP VIEW IF EXISTS staging.stg_uploaded_images")

    alter table(:uploaded_images, prefix: "op") do
      modify :storage_path, :text, null: true
    end
  end

  def down do
    alter table(:uploaded_images, prefix: "op") do
      modify :storage_path, :text, null: false
    end
  end
end
