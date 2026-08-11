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
    - `:endpoint` — API endpoint for admin calls (e.g. "/api/admin/users/by_email")
    - `:latency_ms` — round-trip latency in milliseconds for admin calls
    - `:success` — whether the admin call succeeded
    - `:row_count` — rows returned or affected by the admin call
    - `:operator_session_id` — UUID of the admin session issuing the call
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
    raw_metadata = Keyword.get(opts, :metadata, %{})
    encrypted_metadata = raw_metadata |> Jason.encode!() |> Stacks.Vault.encrypt!()

    operator_session_id = Keyword.get(opts, :operator_session_id)

    params = %{
      id: Ecto.UUID.dump!(entry_id),
      user_id: encode_uuid(user_id),
      action: action,
      resource_type: resource_type,
      resource_id: encode_uuid(Keyword.get(opts, :resource_id)),
      ip_address: ip_address,
      metadata: encrypted_metadata,
      occurred_at: now,
      endpoint: Keyword.get(opts, :endpoint),
      latency_ms: Keyword.get(opts, :latency_ms),
      success: Keyword.get(opts, :success),
      row_count: Keyword.get(opts, :row_count),
      operator_session_id: operator_session_id
    }

    result_params = %{
      params
      | id: entry_id,
        user_id: user_id,
        metadata: raw_metadata
    }

    case Repo.insert_all("audit_log", [params], prefix: "audit") do
      {1, _} ->
        :telemetry.execute([:stacks, :gdpr, :audit, :write], %{count: 1}, %{
          action: action,
          resource_type: resource_type
        })

        {:ok, result_params}

      _ ->
        {:error, :insert_failed}
    end
  rescue
    error -> {:error, error}
  end

  @doc """
    Logs a deploy rollback: audit row (action `"system.rollback"`, type
    `"deploy"`) then a `[:stacks,:system,:rollback]` telemetry event — only
    on successful insert, so a signal never fires for an unrecorded rollback.
    `failed_sha` is the SHA rolled back FROM (not the target); it rides in
    metadata because a git SHA is not a UUID. `triggered_by` ∈ "slo-gate",
    "manual", "step-failure", "migration-failure" (caller-trusted, no guard).
  """
  @spec log_rollback(map()) :: {:ok, map()} | {:error, term()}
  def log_rollback(%{
        failed_sha: failed_sha,
        target_image: target_image,
        modal_prev_commit: modal_prev_commit,
        reason: reason,
        triggered_by: triggered_by
      }) do
    metadata = %{
      failed_sha: failed_sha,
      target_image: target_image,
      modal_prev_commit: modal_prev_commit,
      reason: reason,
      triggered_by: triggered_by
    }

    case log(nil, "system.rollback",
           resource_type: "deploy",
           resource_id: failed_sha,
           metadata: metadata
         ) do
      {:ok, entry} ->
        :telemetry.execute([:stacks, :system, :rollback], %{count: 1}, metadata)
        {:ok, entry}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @default_per_page 25
  @max_per_page 100

  @doc """
    Lists a user's own audit-log entries, newest first, paginated
    (`:page`, `:per_page` — clamped, default #{@default_per_page}/max
    #{@max_per_page}). Read-only and self-scoped. Cloak-encrypted `metadata`
    is decrypted for display; the hashed `ip_address` column is never
    selected. Returns `{entries, total, page, per_page}`.
  """
  @spec list_for_user(binary(), keyword()) ::
          {[map()], non_neg_integer(), pos_integer(), pos_integer()}
  def list_for_user(user_id, opts \\ []) when is_binary(user_id) do
    page = opts |> Keyword.get(:page, 1) |> normalise_page()
    per_page = opts |> Keyword.get(:per_page, @default_per_page) |> clamp_per_page()
    offset = (page - 1) * per_page

    user_id_binary = Ecto.UUID.dump!(user_id)

    total =
      case Repo.query("SELECT COUNT(*) FROM audit.audit_log WHERE user_id = $1", [user_id_binary]) do
        {:ok, %{rows: [[count]]}} -> count
        _ -> 0
      end

    sql = """
    SELECT id, action, resource_type, resource_id, metadata, occurred_at
    FROM audit.audit_log
    WHERE user_id = $1
    ORDER BY occurred_at DESC, id DESC
    LIMIT $2 OFFSET $3
    """

    rows =
      case Repo.query(sql, [user_id_binary, per_page, offset]) do
        {:ok, %{rows: r}} -> r
        _ -> []
      end

    :telemetry.execute([:stacks, :gdpr, :audit, :read], %{count: 1}, %{})

    {Enum.map(rows, &decode_read_row/1), total, page, per_page}
  end

  defp normalise_page(page) when is_integer(page) and page >= 1, do: page
  defp normalise_page(_), do: 1

  defp clamp_per_page(per_page) when is_integer(per_page) and per_page >= 1,
    do: min(per_page, @max_per_page)

  defp clamp_per_page(_), do: @default_per_page

  defp decode_read_row([id, action, resource_type, resource_id, metadata, occurred_at]) do
    %{
      id: decode_read_uuid(id),
      action: action,
      resource_type: resource_type,
      resource_id: decode_read_uuid(resource_id),
      metadata: decrypt_metadata(metadata),
      occurred_at: decode_read_timestamp(occurred_at)
    }
  end

  defp decode_read_uuid(nil), do: nil

  defp decode_read_uuid(bin) when is_binary(bin) and byte_size(bin) == 16,
    do: Ecto.UUID.load!(bin)

  defp decode_read_uuid(other), do: other

  defp decode_read_timestamp(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
  defp decode_read_timestamp(other), do: other

  defp decrypt_metadata(nil), do: %{}

  defp decrypt_metadata(bin) when is_binary(bin) do
    case Stacks.Vault.decrypt(bin) do
      {:ok, json} -> Jason.decode!(json)
      _ -> %{}
    end
  rescue
    _ -> %{}
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
