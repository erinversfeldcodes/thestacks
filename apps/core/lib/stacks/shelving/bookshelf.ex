defmodule Stacks.Shelving.Bookshelf do
  @moduledoc "Schema for op.bookshelves table."

  use Ecto.Schema
  import Ecto.Changeset

  alias Stacks.Accounts.User
  alias Stacks.Shelving.Placement

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @valid_names ~w(antilibrary library wishlist reading_pile looking_for_home)
  @valid_visibilities ~w(owner group platform)

  schema "bookshelves" do
    field :name, :string
    field :visibility, :string, default: "owner"
    field :visibility_group_id, :binary_id

    belongs_to :user, User
    has_many :placements, Placement

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @doc "Changeset for creating or updating a bookshelf."
  def changeset(bookshelf, attrs) do
    bookshelf
    |> cast(attrs, [:user_id, :name, :visibility, :visibility_group_id])
    |> validate_required([:user_id, :name])
    |> validate_inclusion(:name, @valid_names)
    |> validate_inclusion(:visibility, @valid_visibilities)
    |> unique_constraint([:user_id, :name])
  end
end
