defmodule Stacks.Books.Book do
  @moduledoc "Schema for op.books table."

  use Ecto.Schema
  import Ecto.Changeset

  alias Stacks.Books.Author

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @derive {Jason.Encoder,
           only: [
             :id,
             :isbn,
             :title,
             :description,
             :cover_image_url,
             :page_count,
             :publisher,
             :publication_year,
             :language,
             :subjects,
             :bisac_codes,
             :visibility_tier,
             :open_library_id,
             :google_books_id,
             :created_at,
             :updated_at
           ]}

  schema "books" do
    field :isbn, :string
    field :title, :string
    field :description, :string
    field :cover_image_url, :string
    field :page_count, :integer
    field :publisher, :string
    field :publication_year, :integer
    field :language, :string
    field :subjects, {:array, :string}, default: []
    field :bisac_codes, {:array, :string}, default: []
    field :visibility_tier, :string, default: "public"
    field :open_library_id, :string
    field :google_books_id, :string

    belongs_to :author, Author

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @required_fields [:isbn, :title]
  @optional_fields [
    :author_id,
    :description,
    :cover_image_url,
    :page_count,
    :publisher,
    :publication_year,
    :language,
    :subjects,
    :bisac_codes,
    :visibility_tier,
    :open_library_id,
    :google_books_id
  ]

  @doc "Changeset for creating or updating a book."
  def changeset(book, attrs) do
    book
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:isbn, ~r/^\d{10}(\d{3})?$/, message: "must be a valid ISBN-10 or ISBN-13")
    |> validate_inclusion(:visibility_tier, ["public", "age_gated"])
    |> unique_constraint(:isbn)
  end
end
