defmodule Stacks.Enrichment.ReviewSnapshot do
  @moduledoc """
  Schema for `op.review_snapshots` — a scraped review summary for a book
  from an external source (Goodreads, Reddit, StoryGraph, etc.).

  Review snapshots do NOT use `timestamps()` — they track freshness via
  explicit `scraped_at` and `stale_after` fields.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Stacks.Books.Book

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @type t :: %__MODULE__{}

  schema "review_snapshots" do
    field :source, Ecto.Enum, values: [:goodreads, :reddit, :storygraph, :other]
    field :source_url, :string
    field :sentiment_score, :float
    field :summary, :string
    field :rating, :float
    field :rating_count, :integer
    field :scraped_at, :utc_datetime_usec
    field :stale_after, :utc_datetime_usec

    belongs_to :book, Book
  end

  @required_fields [:book_id, :source, :source_url, :scraped_at]
  @optional_fields [:sentiment_score, :summary, :rating, :rating_count, :stale_after]

  @doc "Changeset for creating or updating a review snapshot."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:summary, max: 500)
    |> foreign_key_constraint(:book_id)
  end
end
