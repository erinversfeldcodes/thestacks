defmodule Stacks.Audit do
  @moduledoc """
  Audit logging context. Provides INSERT-only access to the audit_log table.

  All significant user actions are recorded here with hashed IP addresses
  and encrypted metadata. The audit_log has no inserted_at/updated_at —
  it uses occurred_at for timing.
  """

  alias Core.Repo

  @doc """
  Logs an audit entry. This function only ever INSERTs — never updates or deletes.

  ## Options
  - `:resource_type` — type of the resource being acted on (e.g. "book", "user")
  - `:resource_id` — UUID of the resource
  - `:ip` — raw IP string (will be hashed via SHA-256 before storage)
  - `:metadata` — arbitrary map stored as jsonb
  """
  @spec log(binary() | nil, String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def log(user_id, action, opts \\ []) do
    now = DateTime.utc_now()

    ip_address =
      case Keyword.get(opts, :ip) do
        nil -> nil
        ip -> hash_ip(ip)
      end

    resource_type = Keyword.get(opts, :resource_type, "unknown")

    entry_id = Ecto.UUID.generate()

    params = %{
      id: Ecto.UUID.dump!(entry_id),
      user_id: encode_uuid(user_id),
      action: action,
      resource_type: resource_type,
      resource_id: encode_uuid(Keyword.get(opts, :resource_id)),
      ip_address: ip_address,
      metadata: Keyword.get(opts, :metadata, %{}),
      occurred_at: now
    }

    result_params = %{params | id: entry_id, user_id: user_id}

    case Repo.insert_all("audit_log", [params], prefix: "audit") do
      {1, _} -> {:ok, result_params}
      _ -> {:error, :insert_failed}
    end
  rescue
    error -> {:error, error}
  end

  defp hash_ip(ip) when is_binary(ip) do
    :crypto.hash(:sha256, ip)
    |> Base.encode16(case: :lower)
  end

  defp encode_uuid(nil), do: nil

  defp encode_uuid(uuid) when is_binary(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, binary} -> binary
      :error -> nil
    end
  end
end
