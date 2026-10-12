defmodule StacksWeb.Plugs.AuditAdminCall do
  @moduledoc """
      Plug that audits every admin API call.

      Records the start time on `call/2`, then registers a `before_send` callback
      that fires after the controller assembles the response. The callback writes an
      audit row via `Stacks.Audit.log/3` capturing endpoint, latency, HTTP success,
      row count (if set by the controller), and the admin operator session.

      Audit failures are silently swallowed — a failing audit write must never
      fail the admin request.
  """

  import Plug.Conn
  require Logger

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    start_ms = System.monotonic_time(:millisecond)

    conn
    |> assign(:audit_start_ms, start_ms)
    |> register_before_send(&audit_response(&1, start_ms))
  end

  defp audit_response(conn, start_ms) do
    latency_ms = System.monotonic_time(:millisecond) - start_ms
    user = conn.assigns[:current_user]
    session = conn.assigns[:admin_session]
    row_count = conn.assigns[:audit_row_count]
    reason = Map.get(conn.params, "reason")

    user_id = user && user.id
    operator_session_id = session && session.id
    success = conn.status in 200..299

    try do
      Stacks.Audit.log(user_id, "admin.call",
        resource_type: "admin_endpoint",
        endpoint: conn.request_path,
        latency_ms: latency_ms,
        success: success,
        row_count: row_count,
        operator_session_id: operator_session_id,
        metadata: %{reason: safe_reason(reason), method: conn.method}
      )
    rescue
      e ->
        Logger.error("AuditAdminCall: audit write raised #{inspect(e)}")
        :ok
    end

    conn
  end

  @redacted "[redacted: the reason carried personal data]"

  @doc false
  # The erasure endpoint refuses a reason that names a person, because the audit
  # row outlives the erasure it authorises. This hook writes the same parameter
  # into the same row from `register_before_send`, which still runs on that 422 —
  # so without this, the guard refused the address and then stored it anyway.
  #
  # It calls the controller's predicate rather than restating the rule, so the
  # two cannot drift: widening what counts as personal data widens both at once.
  #
  # Redacted rather than dropped. An operator reading the trail should be able to
  # see that a reason was supplied and withheld; a missing key reads as "no reason
  # given", which is a different and untrue story.
  defp safe_reason(reason) do
    if Stacks.Audit.reason_carries_personal_data?(reason) do
      @redacted
    else
      reason
    end
  end
end
