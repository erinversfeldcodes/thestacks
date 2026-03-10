defmodule Stacks.Books.UploadedImage do
  @moduledoc "Schema for op.uploaded_images table."

  use Ecto.Schema
  import Ecto.Changeset

  alias Stacks.Books.Book

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @valid_statuses ~w(pending resolved rejected)

  @type t :: %__MODULE__{}

  schema "uploaded_images" do
    field :storage_path, :string
    field :status, :string, default: "pending"
    field :rejection_reason, :string
    field :uploaded_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :book_ids, {:array, :binary_id}, default: []

    belongs_to :book, Book

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  def changeset(image, attrs) do
    image
    |> cast(attrs, [
      :storage_path,
      :status,
      :rejection_reason,
      :uploaded_at,
      :expires_at,
      :book_id,
      :book_ids
    ])
    |> validate_required([:storage_path, :status, :uploaded_at, :expires_at])
    |> validate_inclusion(:status, @valid_statuses)
  end
end
