defmodule Stacks.Social.VisibilityGrant do
  @moduledoc "Schema for op.visibility_grants — grants visibility of a resource to a specific user."

  use Ecto.Schema
  import Ecto.Changeset

  alias Stacks.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @derive {Jason.Encoder,
           only: [
             :id,
             :resource_type,
             :resource_id,
             :granted_to_id,
             :granted_by_id,
             :created_at
           ]}

  @type t :: %__MODULE__{}

  schema "visibility_grants" do
    field :resource_type, :string
    field :resource_id, :binary_id

    belongs_to :granted_to, User, foreign_key: :granted_to_id
    belongs_to :granted_by, User, foreign_key: :granted_by_id

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
  end

  @required_fields [:resource_type, :resource_id, :granted_to_id, :granted_by_id]
  @optional_fields []

  @doc "Changeset for creating a visibility grant."
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:resource_type, :resource_id, :granted_to_id])
  end
end
