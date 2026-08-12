defmodule Core.Repo.Migrations.MakeStoragePathNullable do
  use Ecto.Migration

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
