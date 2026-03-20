defmodule Core.Repo.Migrations.AddReviewSnapshotsUniqueIndex do
  use Ecto.Migration

  def change do
    create unique_index(:review_snapshots, [:book_id, :source], prefix: "op")
  end
end
