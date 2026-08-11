defmodule Stacks.DataCorrection.EditionIsbn do
  @moduledoc """
    The `op.book_editions.isbn` target, and the one thing that is special about it.

    Everything structural — the guarded `WHERE`, the `to_regclass` check, the
    identifier validation — lives in `Stacks.DataCorrection.Column`. What stays
    here is the part that is true of this column and no other: `isbn` carries a
    unique index, so a repair can collide with a *different* edition that already
    owns the value being written. That is a decision for a human, not a retry, so
    `swap/3` refuses rather than letting the index reject it mid-transaction.
  """

  alias Stacks.DataCorrection.Column

  @target {"op.book_editions", "isbn"}

  @doc "The `{table, column}` this module writes. Exposed for tests and callers."
  @spec target() :: Column.target()
  def target, do: @target

  @doc """
    Rewrites one edition's ISBN, provided the row still holds `from`.

    Returns `{:error, {:isbn_already_present, to}}` when a *different* edition
    already owns `to`.
  """
  @spec swap(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def swap(id, from, to) do
    if Column.taken_by_another?(@target, id, to) do
      {:error, {:isbn_already_present, to}}
    else
      Column.swap(@target, id, from, to)
    end
  end

  @doc """
    Editions whose `isbn` matches `pattern` (a POSIX regex), as `{id, isbn}`.
    Empty when the table does not exist.
  """
  @spec matching(String.t()) :: [{String.t(), String.t()}]
  def matching(pattern), do: Column.matching(@target, pattern)

  @doc """
    Editions whose id is in `ids`, as a map of id string to current `isbn`. Empty
    when the table does not exist.
  """
  @spec by_ids([String.t()]) :: %{optional(String.t()) => String.t()}
  def by_ids(ids), do: Column.by_ids(@target, ids)

  @doc "False on a database that has not been migrated yet."
  @spec table_present?() :: boolean()
  def table_present?, do: Column.table_present?(elem(@target, 0))
end
