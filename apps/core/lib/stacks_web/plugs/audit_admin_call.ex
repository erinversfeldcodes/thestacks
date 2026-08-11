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
        metadata: %{reason: reason, method: conn.method}
      )
    rescue
      e ->
        Logger.error("AuditAdminCall: audit write raised #{inspect(e)}")
        :ok
    end

    conn
  end
end
