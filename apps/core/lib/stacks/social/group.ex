defmodule Stacks.Social.Group do
  @moduledoc "Schema for op.groups — a named collection of users with a shared context."

  use Ecto.Schema
  import Ecto.Changeset

  alias Stacks.Accounts.User
  alias Stacks.Social.{GroupInvitation, GroupMember}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @derive {Jason.Encoder,
           only: [
             :id,
             :owner_id,
             :name,
             :type,
             :visibility,
             :created_at,
             :updated_at
           ]}

  @type t :: %__MODULE__{}

  schema "groups" do
    field :name, :string
    field :type, :string
    field :visibility, :string, default: "invite_only"

    belongs_to :owner, User

    has_many :members, GroupMember
    has_many :invitations, GroupInvitation

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @required_fields [:owner_id, :name, :type]
  @optional_fields [:visibility]

  @valid_types ~w(close_friends broadcast subscription)
  @valid_visibilities ~w(invite_only platform)

  @doc "Changeset for creating or updating a group."
  def changeset(group, attrs) do
    group
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:type, @valid_types)
    |> validate_inclusion(:visibility, @valid_visibilities)
  end
end
