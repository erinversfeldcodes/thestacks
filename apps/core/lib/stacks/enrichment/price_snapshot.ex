defmodule Stacks.Enrichment.PriceSnapshot do
  @moduledoc "Schema for op.price_snapshots table — a scraped price for a book at a store."

  use Ecto.Schema
  import Ecto.Changeset

  alias Stacks.Books.Book
  alias Stacks.Enrichment.Bookstore

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @type t :: %__MODULE__{}

  schema "price_snapshots" do
    field :price_cents, :integer
    field :currency, :string, default: "ZAR"
    field :in_stock, :boolean
    field :url, :string
    field :scraped_at, :utc_datetime_usec

    belongs_to :book, Book
    belongs_to :store, Bookstore
  end

  @required_fields [:book_id, :store_id, :price_cents, :scraped_at]
  @optional_fields [:currency, :in_stock, :url]

  @doc "Changeset for creating or updating a price snapshot."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:price_cents, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:book_id)
    |> foreign_key_constraint(:store_id)
  end
end
