defmodule Core.Repo.Migrations.AddBookIdsToUploadedImages do
  use Ecto.Migration

  def change do
    alter table(:uploaded_images, prefix: "op") do
      add :book_ids, {:array, :binary_id}, default: []
    end
  end
end
