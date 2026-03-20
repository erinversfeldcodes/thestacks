defmodule Stacks.Enrichment.ThirdSpaceEvent do
  @moduledoc "Schema for op.third_space_events — an event listing at a third space."

  use Ecto.Schema
  import Ecto.Changeset

  alias Stacks.Enrichment.ThirdSpace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @type t :: %__MODULE__{}

  schema "third_space_events" do
    field :title, :string
    field :description, :string
    field :event_date, :utc_datetime_usec
    field :recurrence, :string
    field :related_authors, {:array, :string}
    field :source_url, :string
    field :scraped_at, :utc_datetime_usec

    belongs_to :space, ThirdSpace
  end

  @required_fields [:space_id, :title, :event_date, :scraped_at]
  @optional_fields [:description, :recurrence, :related_authors, :source_url]

  @doc "Changeset for creating or updating a third space event."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:space_id)
  end
end
