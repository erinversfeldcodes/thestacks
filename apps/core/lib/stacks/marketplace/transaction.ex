defmodule Stacks.Marketplace.Transaction do
  @moduledoc "Schema for op.transactions — a completed or in-progress sale transaction."

  use Ecto.Schema
  import Ecto.Changeset

  alias Stacks.Accounts.User
  alias Stacks.Marketplace.Listing

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @derive {Jason.Encoder,
           only: [
             :id,
             :listing_id,
             :offer_id,
             :buyer_id,
             :seller_id,
             :amount_cents,
             :currency,
             :payment_provider_ref,
             :payment_status,
             :shipping_provider_ref,
             :shipping_status,
             :shipping_cost_cents,
             :completed_at,
             :created_at
           ]}

  @type t :: %__MODULE__{}

  schema "transactions" do
    field :offer_id, :binary_id
    field :amount_cents, :integer
    field :currency, :string, default: "ZAR"
    field :payment_provider_ref, :string
    field :payment_status, :string, default: "pending"
    field :shipping_provider_ref, :string
    field :shipping_status, :string
    field :shipping_cost_cents, :integer
    field :completed_at, :utc_datetime_usec

    belongs_to :listing, Listing
    belongs_to :buyer, User
    belongs_to :seller, User, foreign_key: :seller_id

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
  end

  @required_fields [:listing_id, :amount_cents, :payment_status]
  @optional_fields [
    :offer_id,
    :buyer_id,
    :seller_id,
    :currency,
    :payment_provider_ref,
    :shipping_provider_ref,
    :shipping_status,
    :shipping_cost_cents,
    :completed_at
  ]

  @valid_payment_statuses ~w(pending paid failed refunded)
  @valid_shipping_statuses ~w(pending shipped delivered returned)

  @doc "Changeset for creating or updating a transaction."
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:payment_status, @valid_payment_statuses)
    |> validate_inclusion(:shipping_status, @valid_shipping_statuses)
  end
end
