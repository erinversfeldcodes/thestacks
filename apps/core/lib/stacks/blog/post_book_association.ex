defmodule Stacks.Blog.PostBookAssociation do
  @moduledoc "Schema for op.post_book_associations — links a blog post to a book with LLM or manual attribution."

  use Ecto.Schema
  import Ecto.Changeset

  alias Stacks.Blog.Post
  alias Stacks.Books.Book

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @derive {Jason.Encoder,
           only: [
             :id,
             :post_id,
             :book_id,
             :confidence,
             :reasoning,
             :source,
             :visible,
             :created_at
           ]}

  @type t :: %__MODULE__{}

  schema "post_book_associations" do
    field :confidence, :float
    field :reasoning, :string
    field :source, :string, default: "llm"
    field :visible, :boolean, default: true

    belongs_to :post, Post
    belongs_to :book, Book

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
  end

  @required_fields [:post_id, :book_id, :confidence, :source]
  @optional_fields [:reasoning, :visible]

  @valid_sources ~w(llm manual)

  @doc "Changeset for creating or updating a post-book association."
  def changeset(assoc, attrs) do
    assoc
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:source, @valid_sources)
  end
end
