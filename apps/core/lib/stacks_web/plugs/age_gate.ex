defmodule StacksWeb.Plugs.AgeGate do
  @moduledoc """
  Enforces age-gating on books with `visibility_tier = "age_gated"`.

  Call this plug inline in controller actions after the book has been fetched
  (not as a pipeline plug), passing the book struct as an option:

      AgeGate.call(conn, book: book)

  If the book's visibility_tier is "age_gated" and the current Guardian user
  either is not authenticated or does not have `age_verified: true`, the plug
  halts the conn with a 403 JSON response.

  For all other visibility tiers the conn is returned unchanged.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Stacks.Accounts.Guardian

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    enforce(conn, Keyword.get(opts, :book))
  end

  @doc """
  Enforces the age gate for a fetched book struct. Call this directly from
  controller actions after fetching the book:

      conn = AgeGate.enforce(conn, book)
      if conn.halted, do: conn, else: render(conn, ...)

  Returns the (possibly halted) conn.
  """
  @spec enforce(Plug.Conn.t(), map() | nil) :: Plug.Conn.t()
  def enforce(conn, %{visibility_tier: "age_gated"}) do
    user = Guardian.Plug.current_resource(conn)

    if age_verified?(user) do
      emit_enforce(:passed)
      conn
    else
      emit_enforce(:blocked)

      conn
      |> put_status(403)
      |> json(%{error: "age_verification_required"})
      |> halt()
    end
  end

  # Non-age-gated books are the common case; count only age-gate decisions
  # so the counter reflects the gate's block/pass ratio, not overall traffic.
  def enforce(conn, _book), do: conn

  # Operational counter for age-gate decisions (Issue #228). `outcome` is a
  # whitelisted atom (:blocked / :passed) — no user id, email, or book
  # identifier in metadata (GDPR: telemetry is warehouse-adjacent).
  defp emit_enforce(outcome) do
    :telemetry.execute([:stacks, :age_gate, :enforce], %{count: 1}, %{outcome: outcome})
  end

  defp age_verified?(nil), do: false
  defp age_verified?(%{age_verified: true}), do: true
  defp age_verified?(_), do: false
end
