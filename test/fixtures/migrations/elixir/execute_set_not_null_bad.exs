defmodule Core.Repo.Migrations.RawTightenHandleNotNull do
  use Ecto.Migration

  # #219 regression fixture: the SAME NOT NULL tighten as `modify :handle,
  # null: false`, but written as raw SQL inside execute(...). Before #219 this
  # slipped past lint-migrations.sh entirely because the linter only matched the
  # `modify … null: false` DSL. There is NO @breaking_ok — the linter must refuse
  # it just as it refuses the DSL form.
  def up do
    execute("ALTER TABLE op.users ALTER COLUMN handle SET NOT NULL")
  end

  def down do
    execute("ALTER TABLE op.users ALTER COLUMN handle DROP NOT NULL")
  end
end
