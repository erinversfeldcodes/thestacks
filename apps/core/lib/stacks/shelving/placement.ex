defmodule Stacks.Shelving.Placement do
  @moduledoc "Schema for op.bookshelf_placements table."

  use Ecto.Schema
  import Ecto.Changeset

  alias Stacks.Books.Book
  alias Stacks.Shelving.Bookshelf

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @valid_visibilities ~w(owner group platform)

  schema "bookshelf_placements" do
    field :position, :integer
    field :placed_at, :utc_datetime_usec
    field :removed_at, :utc_datetime_usec
    field :formats, {:array, :string}, default: []
    field :personal_rating, :integer
    field :notes, :string
    field :visibility, :string, default: "owner"
    field :listing_mode, :string
    field :listing_status, :string
    field :listing_price_cents, :integer
    field :listing_min_price_cents, :integer

    belongs_to :book, Book
    belongs_to :bookshelf, Bookshelf

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @optional_fields [
    :position,
    :placed_at,
    :removed_at,
    :formats,
    :personal_rating,
    :notes,
    :visibility,
    :listing_mode,
    :listing_status,
    :listing_price_cents,
    :listing_min_price_cents
  ]

  @doc "Changeset for creating or updating a placement."
  def changeset(placement, attrs) do
    placement
    |> cast(attrs, [:book_id, :bookshelf_id | @optional_fields])
    |> validate_required([:book_id, :bookshelf_id])
    |> validate_inclusion(:visibility, @valid_visibilities)
    |> validate_number(:personal_rating, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> put_placed_at()
  end

  defp put_placed_at(%Ecto.Changeset{changes: changes} = changeset) do
    case Map.get(changes, :placed_at) do
      nil -> put_change(changeset, :placed_at, DateTime.utc_now())
      _ -> changeset
    end
  end
end
