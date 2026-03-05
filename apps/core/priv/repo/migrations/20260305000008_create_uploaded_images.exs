defmodule Core.Repo.Migrations.CreateUploadedImages do
  use Ecto.Migration

  def up do
    execute("CREATE TYPE op.image_status AS ENUM ('pending', 'resolved', 'rejected')")

    create table(:uploaded_images, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :book_id, references(:books, type: :binary_id, prefix: "op", on_delete: :nothing)
      add :storage_path, :text, null: false
      add :status, :image_status, null: false
      add :rejection_reason, :text
      add :uploaded_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:uploaded_images, [:book_id], prefix: "op")
  end

  def down do
    drop table(:uploaded_images, prefix: "op")
    execute("DROP TYPE IF EXISTS op.image_status")
  end
end
