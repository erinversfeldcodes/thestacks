defmodule Core.Repo.Migrations.InterpolatedSqlBad do
  @moduledoc """
      SQL carrying string interpolation. The linter used to DROP any block
      containing `#\{`, which made interpolation an escape hatch: the keywords
      around the interpolated fragment are exactly as destructive as the
      spelled-out version, and the gate threw them away.
  """
  use Ecto.Migration

  @table "widgets"

  def up do
    execute("ALTER TABLE op.#{@table} ALTER COLUMN created_at TYPE timestamptz")
  end

  def down, do: :ok
end
