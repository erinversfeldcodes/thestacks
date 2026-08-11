defmodule Core.Repo.Migrations.AddRotationGraceToAuthTokenFamilies do
  @moduledoc """
      Rotation grace window: reuse-detection burned the family on ANY
      non-current jti, so a benign rotation race (an in-flight request with
      the just-rotated previous token) spuriously logged the user out. The
      family now records `previous_jti` + `rotated_at`, honoured for a short
      grace window (`:session_rotation_grace`, default 20s) without burning.
      Older/unknown tokens still burn.
  """

  use Ecto.Migration

  def up do
    alter table(:auth_token_families, prefix: "op") do
      add :previous_jti, :text, null: true
      add :rotated_at, :utc_datetime_usec, null: true
    end
  end

  def down do
    alter table(:auth_token_families, prefix: "op") do
      remove :previous_jti
      remove :rotated_at
    end
  end
end
