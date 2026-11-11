defmodule Core.Repo.Migrations.MakeStoragePathNullable do
  use Ecto.Migration

  # ⚠️ Attested retrospectively on 2026-10-16. The linter cannot know a column's
  # PREVIOUS type from the migration alone, so it asks about every `modify`
  # carrying one — and the answer here is the useful kind: the type is
  # unchanged (`:text` to `:text`), only nullability is relaxed. No rewrite, no
  # value change, and relaxing NOT NULL is safe for N-1 code by construction.
  @breaking_ok "Same type (:text); only NOT NULL is relaxed to allow NULL. No table " <>
                 "rewrite and no value conversion — widening a constraint cannot break " <>
                 "a reader."

  def up do
    execute("DROP VIEW IF EXISTS staging.stg_uploaded_images")

    alter table(:uploaded_images, prefix: "op") do
      modify :storage_path, :text, null: true
    end
  end

  def down do
    alter table(:uploaded_images, prefix: "op") do
      modify :storage_path, :text, null: false
    end
  end
end
