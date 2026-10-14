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
  # ⚠️ `action` and `resource_type` are arbitrary strings on the way IN — the
  # function signature says `String.t()` and nothing validates them — and they
  # went straight out as Prometheus labels. Every caller today passes a literal
  # from the sets below, so the values were bounded by caller DISCIPLINE and by
  # nothing else.
  #
  # That is not good enough for a label. A label is a dimension: one series per
  # distinct value, forever. A future caller interpolating a resource name, an
  # email or an id — the obvious thing to do when debugging — would mint a series
  # per value in a store that has no erasure path and, for a family classified
  # public, an anonymous reader.
  #
  # So the ROW keeps the exact string, because the audit log is the record and
  # must be faithful, and the LABEL is bounded to a known set with everything
  # else collapsing to "other". An unexpected action showing up as `other` in the
  # metric is a signal to come and add it here; an unbounded label is a signal
  # nobody gets until the store is already full.
  #
  # These sets are the labels' vocabulary, NOT a validation of what may be
  # audited: a new action writes its row correctly on the day it is added and
  # only its metric needs catching up.
  @telemetry_actions ~w(
    admin.call admin.login admin.mfa_verified
    invite.issued invite.revoked
    placement.created placement.moved placement.removed
    placement.reread placement.restored
    user.data_deleted user.deletion_requested user.login user.registered
  )

  @telemetry_resource_types ~w(
    admin_endpoint admin_session bookshelf deploy invite placement user unknown
  )

  defp bounded_label(value, allowed) when is_binary(value) do
    if value in allowed, do: value, else: "other"
  end

  defp bounded_label(_value, _allowed), do: "other"

  @doc "The action values the write counter may label. Anything else labels as `other`."
  @spec telemetry_actions() :: [String.t()]
  def telemetry_actions, do: @telemetry_actions

  @doc "The resource types the write counter may label. Anything else labels as `other`."
  @spec telemetry_resource_types() :: [String.t()]
  def telemetry_resource_types, do: @telemetry_resource_types

  @doc """
      The label-bounding rule, exposed so it can be asserted rather than trusted.

      The label guard's allowlist carries a written reason for every label key,
      and for these two the reason is about CODE rather than a literal — so the
      reason has to be checkable. An allowlist entry a machine cannot verify is
      a sentence, which this project has shipped before.
  """
  @spec bounded_label_for(term(), [String.t()]) :: String.t()
  def bounded_label_for(value, allowed), do: bounded_label(value, allowed)

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
          action: bounded_label(action, @telemetry_actions),
          resource_type: bounded_label(resource_type, @telemetry_resource_types)
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

  @email_shaped ~r/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/

  @doc """
      Whether an operator-supplied justification carries something that reads as a
      data subject's personal data.

      This exists because a `reason` typed by an operator is stored in an audit
      row, and the row written by an erasure deliberately outlives the erasure —
      so an email pasted into it survives the deletion it was authorising. Until
      now the only control was a docstring asking people not to, which is a wish
      rather than a mechanism.

      ⛔ Deliberately a floor, not a ceiling. It catches the habitual paste — the
      operator who writes "erasing at the request of jane@example.com" — and it
      does not catch "jane at example dot com", a phone number, or a full name.
      Treat a pass as "the obvious mistake was not made", never as "this string
      is clean". The durable fix is to stop putting prose in a retained column at
      all and reference a ticket instead; this guard is what stands in the gap
      until that happens.
  """
  @spec reason_carries_personal_data?(String.t() | nil) :: boolean()
  def reason_carries_personal_data?(nil), do: false

  def reason_carries_personal_data?(reason) when is_binary(reason) do
    Regex.match?(@email_shaped, reason)
  end

  defp hash_ip(ip) when is_binary(ip), do: Stacks.IPDigest.hash(ip)

  defp encode_uuid(nil), do: nil

  defp encode_uuid(uuid) when is_binary(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, binary} -> binary
      :error -> nil
    end
  end
end
