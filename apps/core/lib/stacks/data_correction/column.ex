defmodule Stacks.DataCorrection.Column do
  @moduledoc """
  The write shared by every correction that changes one column of one row.

  #339 built this against `op.book_editions.isbn` and only that column. #340
  lifted the column out, because the second and third real corrections do not
  touch `isbn`: #370 has to rewrite `verification_source` on the same table, and
  an un-merge rewrites a placement's `book_id`. A repair mechanism that can only
  repair one column is a repair for one incident.

  Deliberately raw SQL rather than the Ecto schema. A correction runs because
  reality and the schema disagree, and reading the broken rows through the schema
  that describes the world as it *should* be is how a repair quietly becomes a
  no-op — the changeset normalises the bad value away before you ever see it.

  Three properties are load-bearing:

    * **The `IS NOT DISTINCT FROM` clause on the old value.** A row that moved
      between planning and applying is refused, not overwritten. `IS NOT
      DISTINCT FROM` rather than `=` so a correction whose `from` is `NULL` — a
      backfill — is expressible without a second code path.
    * **Identifiers are matched against `@identifier` before they reach SQL.**
      They come from a compiled correction module rather than from a request, so
      this is a belt on top of braces; the brace is that
      `Stacks.DataCorrection.Registry` is the only way to name a correction, and
      it is an explicit list.
    * **Every read is guarded by `to_regclass`.** Corrections run *before*
      migrations (the repair has to land ahead of the constraint that would
      reject the row), so on a database that has never been migrated the table
      simply is not there yet — and a brand-new database has nothing to correct.
      Without the guard, bringing up a fresh environment would abort on a repair
      for data that cannot exist.

  A correction names its target as `{"op.some_table", "some_column"}`. The table
  is assumed to carry `id` and `updated_at`, which every table in this schema
  does (UUID PKs + TIMESTAMPTZ is a project convention).
  """

  alias Core.Repo

  @typedoc "A correction's write target: `{qualified table, column}`."
  @type target :: {String.t(), String.t()}

  # Lowercase snake_case only, one optional schema qualifier. Anything else
  # raises rather than being escaped — a correction that needs a quoted
  # identifier is a correction that needs a human to look at it.
  @identifier ~r/\A[a-z_][a-z0-9_]*(\.[a-z_][a-z0-9_]*)?\z/

  @doc """
  Rewrites one row's `column`, provided the row still holds `from`.

  Returns `{:error, {:row_no_longer_matches, id, from}}` when it does not — the
  plan was built against a row that has since moved, and guessing which of the
  two values is the intended one is not this function's decision to make.
  """
  @spec swap(target(), String.t(), term(), term()) :: :ok | {:error, term()}
  def swap({table, column} = target, id, from, to) do
    validate!(target)

    sql = """
    UPDATE #{table} SET #{column} = $1, updated_at = now()
    WHERE id = $2 AND #{column} IS NOT DISTINCT FROM $3
    """

    case Repo.query(sql, [to, dump_uuid(id), from]) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> {:error, {:row_no_longer_matches, id, from}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Rows whose `column` matches `pattern` (a POSIX regex), as `{id, value}` with
  the id already loaded to its string form. Empty when the table does not exist.
  """
  @spec matching(target(), String.t()) :: [{String.t(), term()}]
  def matching({table, column} = target, pattern) do
    validate!(target)

    query(
      target,
      "SELECT id, #{column} FROM #{table} WHERE #{column} ~ $1 ORDER BY #{column}",
      [pattern]
    )
  end

  @doc """
  Rows whose `column` is exactly `value`, as `{id, value}`. `nil` selects the
  rows holding SQL NULL, so a backfill can plan the rows it is about to fill.
  Empty when the table does not exist.
  """
  @spec holding(target(), term()) :: [{String.t(), term()}]
  def holding({table, column} = target, value) do
    validate!(target)

    query(
      target,
      "SELECT id, #{column} FROM #{table} WHERE #{column} IS NOT DISTINCT FROM $1 ORDER BY id",
      [value]
    )
  end

  @doc """
  The current `column` value of each id in `ids`, as a map keyed by id string.
  Ids absent from the table are absent from the map. Empty when the table does
  not exist.
  """
  @spec by_ids(target(), [String.t()]) :: %{optional(String.t()) => term()}
  def by_ids({table, column} = target, ids) do
    validate!(target)

    target
    |> query("SELECT id, #{column} FROM #{table} WHERE id = ANY($1)", [
      Enum.map(ids, &dump_uuid/1)
    ])
    |> Map.new()
  end

  @doc """
  Whether any other row already holds `value` in `column`.

  A correction over a uniquely-indexed column asks this before writing, because
  the index would reject the write and a repair that collides with real data is
  a decision for a human, not a retry.
  """
  @spec taken_by_another?(target(), String.t(), term()) :: boolean()
  def taken_by_another?({table, column} = target, id, value) do
    validate!(target)

    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM #{table} WHERE #{column} IS NOT DISTINCT FROM $1 AND id <> $2 LIMIT 1",
        [value, dump_uuid(id)]
      )

    rows != []
  end

  @doc "False on a database that has not been migrated yet."
  @spec table_present?(String.t()) :: boolean()
  def table_present?(table) do
    # ::text because Postgrex has no decoder for the bare `regclass` OID type.
    %{rows: [[regclass]]} = Repo.query!("SELECT to_regclass($1)::text", [table])
    regclass != nil
  end

  defp query({table, _column} = target, sql, params) do
    if table_present?(table) and column_present?(target) do
      %{rows: rows} = Repo.query!(sql, params)
      Enum.map(rows, fn [id, value] -> {load_uuid(id), value} end)
    else
      []
    end
  end

  @doc """
  False on a database whose migrations have not added `column` yet.

  The `to_regclass` guard above covers a table that does not exist; this covers
  the OTHER pre-migration shape — the table exists but the correction's column
  is newer than the branch. Both read as "nothing to correct yet": corrections
  run BEFORE migrations, so on a fresh fork of an older database the sweep must
  come up empty rather than abort the release (the exact failure the
  `seed_edition_verification_source` sweep hit on a staging fork, 2026-08-10:
  Postgrex 42703 in the release command, core deploy dead on both attempts).
  """
  @spec column_present?(target()) :: boolean()
  def column_present?({table, column}) do
    {schema, bare_table} =
      case String.split(table, ".") do
        [schema, bare] -> {schema, bare}
        [bare] -> {"public", bare}
      end

    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT COUNT(*) FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
        """,
        [schema, bare_table, column]
      )

    count > 0
  end

  defp validate!({table, column}) do
    for identifier <- [table, column] do
      unless Regex.match?(@identifier, identifier) do
        raise ArgumentError,
              "#{inspect(identifier)} is not a plain snake_case SQL identifier; " <>
                "a data correction may not name it"
      end
    end

    :ok
  end

  defp dump_uuid(<<_::128>> = raw), do: raw
  defp dump_uuid(string) when is_binary(string), do: Ecto.UUID.dump!(string)

  defp load_uuid(<<_::128>> = raw), do: Ecto.UUID.load!(raw)
  defp load_uuid(string) when is_binary(string), do: string
end
