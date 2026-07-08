defmodule Stacks.AdminSession do
  @moduledoc """
  Ecto schema for the `op.admin_sessions` table.

  Represents a break-glass admin session. The `id` field IS the session_id —
  there is no separate column. Sessions expire after 30 minutes and can be
  revoked explicitly. MFA verification is tracked via `mfa_verified_at`.
  """

  use Ecto.Schema

  @schema_prefix "op"
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "admin_sessions" do
    field :ip_hash, :string
    field :boot_id, :string
    field :mfa_verified_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :user, Stacks.Accounts.User

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
