defmodule Stacks.Marketplace.OfferThread do
  @moduledoc "Schema for op.offer_threads — a negotiation thread between a buyer and a seller's placement."

  use Ecto.Schema
  import Ecto.Changeset

  alias Stacks.Accounts.User
  alias Stacks.Marketplace.OfferMessage
  alias Stacks.Shelving.Placement

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @derive {Jason.Encoder,
           only: [
             :id,
             :placement_id,
             :buyer_id,
             :status,
             :created_at,
             :updated_at
           ]}

  @type t :: %__MODULE__{}

  schema "offer_threads" do
    field :status, :string, default: "open"

    belongs_to :placement, Placement
    belongs_to :buyer, User

    has_many :messages, OfferMessage, foreign_key: :thread_id

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @required_fields [:placement_id, :buyer_id]
  @optional_fields [:status]

  @valid_statuses ~w(open accepted declined expired)

  @doc "Changeset for creating or updating an offer thread."
  def changeset(thread, attrs) do
    thread
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint([:placement_id, :buyer_id])
  end
end
