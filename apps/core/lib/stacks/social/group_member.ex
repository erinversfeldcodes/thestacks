defmodule Stacks.Social.GroupMember do
  @moduledoc "Schema for op.group_members — membership record linking a user to a group."

  use Ecto.Schema
  import Ecto.Changeset

  alias Stacks.Accounts.User
  alias Stacks.Social.Group

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @derive {Jason.Encoder,
           only: [
             :id,
             :group_id,
             :user_id,
             :role,
             :joined_at,
             :created_at
           ]}

  @type t :: %__MODULE__{}

  schema "group_members" do
    field :role, :string, default: "member"
    field :joined_at, :utc_datetime_usec

    belongs_to :group, Group
    belongs_to :user, User

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
  end

  @required_fields [:group_id, :user_id, :role]
  @optional_fields [:joined_at]

  @valid_roles ~w(member moderator)

  @doc "Changeset for adding a member to a group."
  def changeset(member, attrs) do
    member
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:role, @valid_roles)
    |> unique_constraint([:group_id, :user_id])
  end
end
