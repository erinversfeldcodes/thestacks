defmodule Core.Repo.Migrations.CreateThings do
  use Ecto.Migration

  # Canonical create_table migration with explicit up/down. The `drop table`
  # in `def down` is the standard reversal — it must NOT count as destructive,
  # since it only fires on `mix ecto.rollback`, never on a forward deploy.
  def up do
    create table(:things, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:things, [:name], prefix: "op")
  end

  def down do
    drop table(:things, prefix: "op")
  end
end
