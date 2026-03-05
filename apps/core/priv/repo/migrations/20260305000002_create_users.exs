defmodule Core.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def up do
    execute("CREATE TYPE op.user_role AS ENUM ('owner', 'user')")

    create table(:users, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :text, null: false
      add :password_hash, :text, null: false
      add :display_name, :text
      add :role, :user_role, default: "user", null: false
      add :age_verified, :boolean, default: false
      add :age_verified_at, :utc_datetime_usec
      add :age_verification_provider, :text
      add :country_code, :text, default: "ZA"
      add :city, :text
      add :consent_analytics, :boolean, default: false
      add :consent_analytics_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email], prefix: "op")
  end

  def down do
    drop table(:users, prefix: "op")
    execute("DROP TYPE IF EXISTS op.user_role")
  end
end
