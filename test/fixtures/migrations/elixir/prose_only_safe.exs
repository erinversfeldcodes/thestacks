defmodule Core.Repo.Migrations.ProseOnlySafe do
  @moduledoc """
      Discusses destructive operations without performing any. A previous
      iteration of the SQL extraction scanned every string in the file including
      the docs, so a migration that merely explained why it was NOT dropping a
      column would have been flagged for mentioning `DROP COLUMN` and
      `ALTER COLUMN ... TYPE timestamptz`.

      This fixture is the negative half of widening the extraction: the match has
      to mean something, or the attestation it demands stops meaning anything.
  """
  use Ecto.Migration

  def up do
    # Also prose: a plain comment naming RENAME COLUMN and SET NOT NULL.
    alter table(:widgets, prefix: "op") do
      add :note, :text
    end
  end

  def down do
    alter table(:widgets, prefix: "op") do
      remove :note
    end
  end
end
