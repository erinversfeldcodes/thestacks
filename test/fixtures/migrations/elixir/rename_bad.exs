defmodule Core.Repo.Migrations.RenameCoverImageUrl do
  use Ecto.Migration

  # Destructive rename with no @breaking_ok — linter should refuse.
  # Note: written as a multi-line `rename` call to prove the parser handles
  # split arguments, not just single-line.
  def change do
    rename table(:books, prefix: "op"),
           :cover_image_url,
           to: :cover_url
  end
end
