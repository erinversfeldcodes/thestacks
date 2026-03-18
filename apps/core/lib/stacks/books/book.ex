defmodule Stacks.Books.Book do
  @moduledoc "Schema for op.books table — represents a work (the logical book)."

  use Ecto.Schema
  import Ecto.Changeset

  alias Stacks.Books.{Author, BookEdition}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @derive {Jason.Encoder,
           only: [
             :id,
             :title,
             :description,
             :language,
             :subjects,
             :bisac_codes,
             :visibility_tier,
             :created_at,
             :updated_at
           ]}

  @type t :: %__MODULE__{}

  schema "books" do
    field :title, :string
    field :description, :string
    field :language, :string
    field :subjects, {:array, :string}, default: []
    field :bisac_codes, {:array, :string}, default: []
    field :visibility_tier, :string, default: "public"

    belongs_to :author, Author
    has_many :editions, BookEdition

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @required_fields [:title]
  @optional_fields [
    :author_id,
    :description,
    :language,
    :subjects,
    :bisac_codes,
    :visibility_tier
  ]

  @doc "Changeset for creating or updating a book (work)."
  def changeset(book, attrs) do
    book
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:visibility_tier, ["public", "age_gated"])
  end
end
