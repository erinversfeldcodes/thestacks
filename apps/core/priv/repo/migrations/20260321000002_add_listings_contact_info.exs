defmodule Core.Repo.Migrations.AddListingsContactInfo do
  use Ecto.Migration

  def change do
    alter table(:listings, prefix: "op") do
      add :contact_info, :text
    end
  end
end
