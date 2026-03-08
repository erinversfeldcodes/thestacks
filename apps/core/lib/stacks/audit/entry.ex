defmodule Stacks.Audit.Entry do
  @moduledoc """
  Schema for audit.audit_log table. INSERT-only — never updated or deleted.
  Note: this table has no inserted_at/updated_at — it uses occurred_at only.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "audit"

  schema "audit_log" do
    field :user_id, :binary_id
    field :action, :string
    field :resource_type, :string
    field :resource_id, :binary_id
    field :ip_address, :string
    field :metadata, :map
    field :occurred_at, :utc_datetime_usec
  end
end
