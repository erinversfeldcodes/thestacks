defmodule Stacks.Books.BookEdition do
  @moduledoc "Schema for op.book_editions table — a specific ISBN/format of a work."

  use Ecto.Schema
  import Ecto.Changeset

  alias Stacks.Books.Book

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @derive {Jason.Encoder,
           only: [
             :id,
             :isbn,
             :format_label,
             :cover_image_url,
             :page_count,
             :publisher,
             :publication_year,
             :open_library_id,
             :google_books_id,
             :is_primary,
             :created_at,
             :updated_at
           ]}

  @type t :: %__MODULE__{}

  schema "book_editions" do
    field :isbn, :string
    field :format_label, :string
    field :cover_image_url, :string
    field :page_count, :integer
    field :publisher, :string
    field :publication_year, :integer
    field :open_library_id, :string
    field :google_books_id, :string
    field :is_primary, :boolean, default: false

    belongs_to :book, Book

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @required_fields [:isbn, :book_id]
  @optional_fields [
    :format_label,
    :cover_image_url,
    :page_count,
    :publisher,
    :publication_year,
    :open_library_id,
    :google_books_id,
    :is_primary
  ]

  @doc "Changeset for creating or updating a book edition."
  def changeset(edition, attrs) do
    edition
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:isbn, ~r/^\d{10}(\d{3})?$/, message: "must be a valid ISBN-10 or ISBN-13")
    |> validate_isbn_checksum()
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

  defp isbn10_valid?(digits) do
    sum =
      digits
      |> Enum.take(9)
      |> Enum.with_index()
      |> Enum.reduce(0, fn {d, i}, acc -> acc + d * (10 - i) end)

    check = rem(11 - rem(sum, 11), 11)
    check != 10 and check == Enum.at(digits, 9)
  end
end
