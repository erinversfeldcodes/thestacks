defmodule Stacks.Marketplace.OfferMessage do
  @moduledoc "Schema for op.offer_messages — a message or offer within a negotiation thread."

  use Ecto.Schema
  import Ecto.Changeset

  alias Stacks.Accounts.User
  alias Stacks.Marketplace.OfferThread

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @derive {Jason.Encoder,
           only: [
             :id,
             :thread_id,
             :sender_id,
             :type,
             :body,
             :amount_cents,
             :created_at
           ]}

  @type t :: %__MODULE__{}

  schema "offer_messages" do
    field :type, :string
    field :body, :string
    field :amount_cents, :integer

    belongs_to :thread, OfferThread
    belongs_to :sender, User

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
  end

  @required_fields [:thread_id, :sender_id, :type]
  @optional_fields [:body, :amount_cents]

  @valid_types ~w(message offer counter accept decline)

  @doc "Changeset for creating an offer message."
  def changeset(message, attrs) do
    message
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:type, @valid_types)
  end
end
