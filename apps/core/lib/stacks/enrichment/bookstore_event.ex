defmodule Stacks.Enrichment.BookstoreEvent do
  @moduledoc "Schema for op.bookstore_events — an event listing scraped from a bookstore website."

  use Ecto.Schema
  import Ecto.Changeset

  alias Stacks.Books.Author
  alias Stacks.Enrichment.Bookstore

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @type t :: %__MODULE__{}

  schema "bookstore_events" do
    field :title, :string
    field :description, :string
    field :event_date, :utc_datetime_usec
    field :location, :string
    field :url, :string
    field :scraped_at, :utc_datetime_usec

    belongs_to :store, Bookstore
    belongs_to :author, Author
  end

  @required_fields [:store_id, :title, :event_date, :scraped_at]
  @optional_fields [:description, :location, :url, :author_id]

  @doc "Changeset for creating or updating a bookstore event."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:store_id)
    |> foreign_key_constraint(:author_id)
  end
end
