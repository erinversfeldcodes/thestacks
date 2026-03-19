defmodule Stacks.Social.GroupInvitation do
  @moduledoc "Schema for op.group_invitations — an invitation for a user to join a group."

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
             :invited_by_id,
             :invited_user_id,
             :status,
             :responded_at,
             :created_at
           ]}

  @type t :: %__MODULE__{}

  schema "group_invitations" do
    field :status, :string, default: "pending"
    field :responded_at, :utc_datetime_usec

    belongs_to :group, Group
    belongs_to :invited_by_user, User, foreign_key: :invited_by_id
    belongs_to :invited_user, User, foreign_key: :invited_user_id

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
  end

  @required_fields [:group_id, :invited_by_id, :invited_user_id, :status]
  @optional_fields [:responded_at]

  @valid_statuses ~w(pending accepted declined)

  @doc "Changeset for creating or updating a group invitation."
  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @valid_statuses)
  end
end
