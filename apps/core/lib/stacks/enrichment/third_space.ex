defmodule Stacks.Enrichment.ThirdSpace do
  @moduledoc "Schema for op.third_spaces — community spaces like cafes, reading groups, and bookshops."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @type t :: %__MODULE__{}

  schema "third_spaces" do
    field :name, :string
    field :type, Ecto.Enum, values: [:reading_group, :cafe, :bookshop, :festival, :market]
    field :city, :string
    field :country_code, :string, default: "ZA"
    field :instagram_url, :string
    field :website_url, :string
    field :description, :string
    field :discovered_via, :string
    field :verified, :boolean, default: false
    field :last_active_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @required_fields [:name, :type]
  @optional_fields [
    :city,
    :country_code,
    :instagram_url,
    :website_url,
    :description,
    :discovered_via,
    :verified,
    :last_active_at
  ]

  @doc "Changeset for creating or updating a third space."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(space, attrs) do
    space
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
