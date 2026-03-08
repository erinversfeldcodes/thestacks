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

  @type t :: %__MODULE__{}

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
    |> validate_isbn_checksum()
    |> validate_inclusion(:visibility_tier, ["public", "age_gated"])
    |> unique_constraint(:isbn)
  end

  defp validate_isbn_checksum(changeset) do
    validate_change(changeset, :isbn, fn :isbn, isbn ->
      if valid_isbn_checksum?(isbn) do
        []
      else
        [isbn: "has an invalid checksum"]
      end
    end)
  end

  defp valid_isbn_checksum?(isbn) do
    # Only validate digit-only ISBNs of the correct length.
    # Non-digit or wrong-length values are caught by validate_format — return true
    # here to avoid adding a redundant second error on the same field.
    if isbn =~ ~r/^\d{10}$|^\d{13}$/ do
      digits = Enum.map(String.graphemes(isbn), &String.to_integer/1)

      case length(digits) do
        13 -> isbn13_valid?(digits)
        10 -> isbn10_valid?(digits)
        _ -> false
      end
    else
      true
    end
  end

  # EAN-13 checksum: alternating weights 1 and 3, total mod 10 == 0
  defp isbn13_valid?(digits) do
    sum =
      digits
      |> Enum.with_index()
      |> Enum.reduce(0, fn {d, i}, acc ->
        weight = if rem(i, 2) == 0, do: 1, else: 3
        acc + d * weight
      end)

    rem(sum, 10) == 0
  end

  # ISBN-10 checksum: positions 10..2 weighted, check digit (position 1) satisfies mod 11.
  # X as check digit is not accepted here since the format regex requires digits only.
  defp isbn10_valid?(digits) do
    sum =
      digits
      |> Enum.take(9)
      |> Enum.with_index()
      |> Enum.reduce(0, fn {d, i}, acc -> acc + d * (10 - i) end)

    check = rem(11 - rem(sum, 11), 11)
    # check == 10 means the check digit should be X — rejected by the format validator
    check != 10 and check == Enum.at(digits, 9)
  end
end
