defmodule Core.Repo.Migrations.AddEmailConfirmationAndPasswordResetToUsers do
  use Ecto.Migration

  def change do
    alter table(:users, prefix: "op") do
      add :email_confirmed, :boolean, null: false, default: false
      add :email_confirmation_token, :text, null: true
      add :password_reset_token, :text, null: true
      add :password_reset_sent_at, :timestamptz, null: true
    end
  end
end
