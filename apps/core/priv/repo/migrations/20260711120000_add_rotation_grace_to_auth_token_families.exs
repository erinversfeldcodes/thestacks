defmodule Core.Repo.Migrations.AddRotationGraceToAuthTokenFamilies do
  @moduledoc """
  Rotation grace window (Issue #180, Phase 1).

  #179's reuse-detection burns the whole family when a presented token's `jti`
  differs from the family's `current_jti`. That makes a benign rotation race —
  an in-flight request carrying the just-rotated *previous* token — burn the
  family and spuriously log the user out. To soften it, the family now records
  the immediately-previous token (`previous_jti`) and when the rotation happened
  (`rotated_at`), so `check_token_family/3` can honour the immediate predecessor
  for a short grace window (config `:session_rotation_grace`, default 20s)
  WITHOUT burning. Anything else (an older token, an unknown jti, the previous
  token past grace) still burns — #179's posture holds outside the window.

  Both columns are additive + nullable (a never-rotated / login-only family
  leaves them nil → no grace). No index (the gate reads the family by its PK).
  The existing table grant to stacks_app covers the new columns; stacks_dbt
  remains ungranted. Independent of the op.guardian_tokens jwt-null trigger
  (different table).
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
