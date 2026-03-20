defmodule Stacks.Books.Author do
  @moduledoc "Schema for op.authors table."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"
  @type t :: %__MODULE__{}

  schema "authors" do
    field :name, :string
    field :bio, :string
    field :website_url, :string
    field :rss_feed_url, :string
    field :open_library_id, :string

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @doc "Changeset for creating or updating an author."
  def changeset(author, attrs) do
    author
    |> cast(attrs, [:name, :bio, :website_url, :rss_feed_url, :open_library_id])
    |> validate_required([:name])
  end
end
