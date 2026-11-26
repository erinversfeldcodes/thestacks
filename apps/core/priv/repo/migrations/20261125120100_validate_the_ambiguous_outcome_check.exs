defmodule Core.Repo.Migrations.ValidateTheAmbiguousOutcomeCheck do
  @moduledoc """
      Validates the widened `op.llm_call_log.outcome_is_known` CHECK that the
      sibling migration added `NOT VALID`. Its own migration, out of a
      transaction, because `VALIDATE CONSTRAINT` scans the table under a SHARE
      UPDATE EXCLUSIVE lock — which allows reads and writes — only when it is not
      wrapped in the migration transaction; inside one it would hold the stronger
      lock for the scan. Every existing row already satisfies the wider set, so
      the scan is a formality, but the lock discipline is the same regardless.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("SET lock_timeout = '5s'")
    execute("SET statement_timeout = 0")
    execute("ALTER TABLE op.llm_call_log VALIDATE CONSTRAINT outcome_is_known")
  end

  def down, do: :ok
end
