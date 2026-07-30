defmodule Stacks.DataCorrection.EditionIsbn do
  @moduledoc """
  The write shared by every correction that changes `op.book_editions.isbn`.

  Deliberately raw SQL rather than `Stacks.Books.BookEdition`: a correction runs
  because reality and the schema disagree, and reading the broken rows through
  the schema that describes the world as it should be is how a repair quietly
  becomes a no-op. The `WHERE isbn = $3` clause is the point — a row that moved
  between planning and applying is refused, not overwritten.

  Every read is guarded by `to_regclass`. Corrections run *before* migrations
  (the repair has to land ahead of the constraint that would reject the row), so
  on a database that has never been migrated the table simply is not there yet —
  and a brand-new database has nothing to correct. Without the guard, bringing
  up a fresh environment would abort on a repair for data that cannot exist.
  """

  alias Core.Repo

  @table "op.book_editions"

  @doc """
  Rewrites one edition's ISBN, provided the row still holds `from`.

  Returns `{:error, {:isbn_already_present, to}}` when a *different* edition
  already owns `to` — the unique index would reject the write, and a repair
  that collides with real data is a decision for a human, not a retry.
  """
  @spec swap(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def swap(id, from, to) do
    if taken_by_another?(id, to) do
      {:error, {:isbn_already_present, to}}
    else
      case Repo.query(
             "UPDATE op.book_editions SET isbn = $1, updated_at = now() WHERE id = $2 AND isbn = $3",
             [to, dump_uuid(id), from]
           ) do
        {:ok, %{num_rows: 1}} -> :ok
        {:ok, %{num_rows: 0}} -> {:error, {:row_no_longer_matches, id, from}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Editions whose `isbn` matches `pattern` (a POSIX regex), as `{id, isbn}` with
  the id already loaded to its string form. Empty when the table does not exist.
  """
  @spec matching(String.t()) :: [{String.t(), String.t()}]
  def matching(pattern) do
    if table_present?() do
      %{rows: rows} =
        Repo.query!("SELECT id, isbn FROM op.book_editions WHERE isbn ~ $1 ORDER BY isbn", [
          pattern
        ])

      Enum.map(rows, fn [id, isbn] -> {load_uuid(id), isbn} end)
    else
      []
    end
  end

  @doc """
  Editions whose id is in `ids`, as a map of id string to current `isbn`. Empty
  when the table does not exist.
  """
  @spec by_ids([String.t()]) :: %{optional(String.t()) => String.t()}
  def by_ids(ids) do
    if table_present?() do
      %{rows: rows} =
        Repo.query!("SELECT id, isbn FROM op.book_editions WHERE id = ANY($1)", [
          Enum.map(ids, &dump_uuid/1)
        ])

      Map.new(rows, fn [id, isbn] -> {load_uuid(id), isbn} end)
    else
      %{}
    end
  end

  @doc "False on a database that has not been migrated yet."
  @spec table_present?() :: boolean()
  def table_present? do
    # ::text because Postgrex has no decoder for the bare `regclass` OID type.
    %{rows: [[regclass]]} = Repo.query!("SELECT to_regclass($1)::text", [@table])
    regclass != nil
  end

  defp taken_by_another?(id, isbn) do
    %{rows: rows} =
      Repo.query!("SELECT 1 FROM op.book_editions WHERE isbn = $1 AND id <> $2 LIMIT 1", [
        isbn,
        dump_uuid(id)
      ])

    rows != []
  end

  defp dump_uuid(<<_::128>> = raw), do: raw
  defp dump_uuid(string) when is_binary(string), do: Ecto.UUID.dump!(string)

  defp load_uuid(<<_::128>> = raw), do: Ecto.UUID.load!(raw)
  defp load_uuid(string) when is_binary(string), do: string
end
