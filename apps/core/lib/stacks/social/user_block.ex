defmodule Stacks.Social.UserBlock do
  @moduledoc "Schema for op.user_blocks — records a user blocking another user."

  use Ecto.Schema
  import Ecto.Changeset

  alias Stacks.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @derive {Jason.Encoder,
           only: [
             :id,
             :blocker_id,
             :blocked_id,
             :created_at
           ]}

  @type t :: %__MODULE__{}

  schema "user_blocks" do
    belongs_to :blocker, User
    belongs_to :blocked, User

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
  end

  @required_fields [:blocker_id, :blocked_id]
  @optional_fields []

  @doc "Changeset for creating a user block."
  def changeset(user_block, attrs) do
    user_block
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:blocker_id, :blocked_id])
  end
end
