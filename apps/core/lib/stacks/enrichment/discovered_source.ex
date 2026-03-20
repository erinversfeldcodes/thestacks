defmodule Stacks.Enrichment.DiscoveredSource do
  @moduledoc """
  Schema for the `op.discovered_sources` table.

  Represents a bookshop, review site, community space, or event source
  discovered via automated search (Brave/SearXNG) or manual submission.
  Each source passes through a status lifecycle:

    pending_review → approved | dismissed | excluded

  Sources may be excluded via the public opt-out endpoint.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @type t :: %__MODULE__{}

  schema "discovered_sources" do
    field :name, :string
    field :type, Ecto.Enum, values: [:bookshop, :review_site, :community, :event_source]
    field :url, :string
    field :confidence, :float
    field :discovered_via, :string
    field :discovered_at, :utc_datetime_usec

    field :status, Ecto.Enum, values: [:pending_review, :approved, :dismissed, :excluded]
    field :approved_at, :utc_datetime_usec
    field :config_generated, :map
    field :excluded_at, :utc_datetime_usec
    field :exclusion_email, :string

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @doc "Changeset for creating a new discovered source."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = source, attrs) do
    source
    |> cast(attrs, [
      :name,
      :type,
      :url,
      :confidence,
      :discovered_via,
      :discovered_at,
      :status,
      :approved_at,
      :config_generated,
      :excluded_at,
      :exclusion_email
    ])
    |> validate_required([:name, :type, :url, :discovered_at, :status])
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> unique_constraint(:url)
  end

  @doc "Changeset for updating status."
  @spec status_changeset(t(), map()) :: Ecto.Changeset.t()
  def status_changeset(%__MODULE__{} = source, attrs) do
    source
    |> cast(attrs, [:status, :approved_at, :excluded_at, :exclusion_email])
    |> validate_required([:status])
  end

  @doc "Changeset for updating confidence score."
  @spec confidence_changeset(t(), map()) :: Ecto.Changeset.t()
  def confidence_changeset(%__MODULE__{} = source, attrs) do
    source
    |> cast(attrs, [:confidence])
    |> validate_required([:confidence])
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  end
end
