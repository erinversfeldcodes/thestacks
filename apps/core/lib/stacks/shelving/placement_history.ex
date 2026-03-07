defmodule Stacks.Shelving.PlacementHistory do
  @moduledoc """
  Schema for op.bookshelf_placement_history table.

  Records book movements between shelves. Stores the source/destination shelf
  UUIDs as plain fields (from_bookshelf, to_bookshelf) and the book_id.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  schema "bookshelf_placement_history" do
    field :book_id, :binary_id
    field :from_bookshelf, :binary_id
    field :to_bookshelf, :binary_id
    field :moved_at, :utc_datetime_usec
  end

  @doc "Changeset for recording a shelf move."
  def changeset(history, attrs) do
    history
    |> cast(attrs, [:book_id, :from_bookshelf, :to_bookshelf, :moved_at])
    |> validate_required([:book_id, :from_bookshelf, :to_bookshelf])
    |> put_moved_at()
  end

  defp put_moved_at(%Ecto.Changeset{changes: changes} = changeset) do
    case Map.get(changes, :moved_at) do
      nil -> put_change(changeset, :moved_at, DateTime.utc_now())
      _ -> changeset
    end
  end
end
