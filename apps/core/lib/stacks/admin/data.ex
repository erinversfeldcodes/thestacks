defmodule Stacks.Admin.Data do
  @moduledoc """
      Admin data access context.

      Provides safe, auditable read access to user data and platform statistics
      for the break-glass admin interface. All returned user maps deliberately
      omit sensitive credential fields (password_hash, reset tokens, etc.).
  """

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Accounts.User
  alias Stacks.Books.Book
  alias Stacks.Marketplace.Listing
  alias Stacks.Shelving.{Bookshelf, Placement}

  @safe_user_fields [
    :id,
    :email,
    :display_name,
    :role,
    :email_confirmed,
    :age_verified,
    :profile_visibility,
    :created_at,
    :updated_at
  ]

  @doc """
      Look up a user by email address (case-insensitive).

      Returns a safe map of user fields — never includes credential or token fields.
  """
  @spec get_user_by_email(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_user_by_email(email) do
    case Accounts.get_user_by_email(email) do
      nil -> {:error, :not_found}
      user -> {:ok, safe_user_map(user)}
    end
  end

  @doc """
      Look up a user by UUID.

      Returns a safe map of user fields — never includes credential or token fields.
  """
  @spec get_user_by_id(binary()) :: {:ok, map()} | {:error, :not_found}
  def get_user_by_id(id) do
    case Accounts.get_user(id) do
      nil -> {:error, :not_found}
      user -> {:ok, safe_user_map(user)}
    end
  end

  @doc """
      Query the audit log for a user within a date range.

      Returns up to 200 entries ordered by `occurred_at DESC`. The `metadata`
      column is excluded because it is Cloak-encrypted bytea and cannot be safely
      returned as-is to callers.

      `user_id` values in the result are formatted UUID strings.
      `occurred_at` values are `%DateTime{}` structs in UTC.
  """
  @spec list_audit_log(binary(), DateTime.t(), DateTime.t()) ::
          {:ok, [map()]} | {:error, :invalid_params}
  def list_audit_log(nil, _from_dt, _to_dt), do: {:error, :invalid_params}

  def list_audit_log(user_id, %DateTime{} = from_dt, %DateTime{} = to_dt) do
    sql = """
    SELECT id, user_id, action, resource_type, endpoint, latency_ms, success, row_count,
           operator_session_id, occurred_at
    FROM audit.audit_log
    WHERE user_id = $1 AND occurred_at >= $2 AND occurred_at <= $3
    ORDER BY occurred_at DESC
    LIMIT 200
    """

    user_id_binary = Ecto.UUID.dump!(user_id)

    case Repo.query(sql, [user_id_binary, from_dt, to_dt]) do
      {:ok, %{rows: rows, columns: columns}} ->
        entries = Enum.map(rows, &decode_audit_row(columns, &1))
        {:ok, entries}

      {:error, _reason} ->
        {:error, :invalid_params}
    end
  end

  @doc """
      Returns aggregate platform statistics (record counts per major entity).
  """
  @spec platform_stats() :: {:ok, map()}
  def platform_stats do
    stats = %{
      users: Repo.aggregate(User, :count),
      books: Repo.aggregate(Book, :count),
      bookshelves: Repo.aggregate(Bookshelf, :count),
      placements: Repo.aggregate(Placement, :count),
      listings: Repo.aggregate(Listing, :count)
    }

    {:ok, stats}
  end

  defp decode_audit_row(columns, row) do
    columns
    |> Enum.zip(row)
    |> Map.new()
    |> Map.update!("id", &decode_uuid/1)
    |> Map.update!("user_id", &decode_uuid/1)
    |> Map.update!("occurred_at", &decode_timestamp/1)
    |> atomize_keys()
  end

  defp decode_uuid(nil), do: nil
  defp decode_uuid(bin) when is_binary(bin) and byte_size(bin) == 16, do: Ecto.UUID.load!(bin)
  defp decode_uuid(str), do: str

  defp decode_timestamp(nil), do: nil
  defp decode_timestamp(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
  defp decode_timestamp(dt), do: dt

  defp safe_user_map(%User{} = user) do
    Map.take(user, @safe_user_fields)
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end
end
