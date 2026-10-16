defmodule Core.Repo.Migrations.HelperBuiltSqlBad do
  @moduledoc """
      SQL assembled in a private helper rather than written at the `execute`
      call site. The linter once looked only inside `execute("…")` literals, so a
      migration shaped like this presented NO SQL to the gate at all and passed
      with no attestation whatever it did.
  """
  use Ecto.Migration

  def up do
    execute(drop_the_column())
  end

  def down, do: :ok

  defp drop_the_column do
    """
    ALTER TABLE op.widgets DROP COLUMN legacy_note;
    """
  end
end
