defmodule Stacks.Marketplace.Listing do
  @moduledoc "Schema for op.listings — a book listed for sale by a user."

  use Ecto.Schema
  import Ecto.Changeset

  alias Stacks.Accounts.User
  alias Stacks.Books.Book
  alias Stacks.Marketplace.Transaction

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @derive {Jason.Encoder,
           only: [
             :id,
             :book_id,
             :seller_id,
             :status,
             :pricing_mode,
             :price_cents,
             :currency,
             :condition,
             :description,
             :photo_urls,
             :listed_at,
             :expires_at,
             :sold_at,
             :created_at,
             :updated_at
           ]}

  @type t :: %__MODULE__{}

  schema "listings" do
    field :status, :string, default: "draft"
    field :pricing_mode, :string
    field :price_cents, :integer
    field :currency, :string, default: "ZAR"
    field :condition, :string
    field :description, :string
    field :photo_urls, {:array, :string}, default: []
    field :listed_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :sold_at, :utc_datetime_usec

    belongs_to :book, Book
    belongs_to :seller, User

    has_many :transactions, Transaction

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @required_fields [:book_id, :seller_id, :pricing_mode, :price_cents, :condition]
  @optional_fields [
    :status,
    :currency,
    :description,
    :photo_urls,
    :listed_at,
    :expires_at,
    :sold_at
  ]

  @valid_statuses ~w(draft active sold removed expired)
  @valid_pricing_modes ~w(fixed offer)
  @valid_conditions ~w(new like_new good fair poor)

  @doc "Changeset for creating or updating a listing."
  def changeset(listing, attrs) do
    listing
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:pricing_mode, @valid_pricing_modes)
    |> validate_inclusion(:condition, @valid_conditions)
  end
end
