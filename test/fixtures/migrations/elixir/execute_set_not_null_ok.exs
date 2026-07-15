defmodule Core.Repo.Migrations.RawTightenHandleNotNullContract do
  use Ecto.Migration

  # #219 regression fixture: the annotated twin of execute_set_not_null_bad.
  # Same raw `ALTER … SET NOT NULL`, but the author has attested the expand
  # phase shipped. The linter must accept it AND echo the reason to stdout.
  @breaking_ok "raw-execute NOT NULL tighten fixture: handle is written on every insert and backfilled; N-1 code no longer inserts null handles"

  def up do
    execute("ALTER TABLE op.users ALTER COLUMN handle SET NOT NULL")
  end

  def down do
    execute("ALTER TABLE op.users ALTER COLUMN handle DROP NOT NULL")
  end
end
