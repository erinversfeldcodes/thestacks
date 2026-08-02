defmodule StacksWeb.DataCorrectionController do
  @moduledoc """
  The platform owner's view of `Stacks.DataCorrection` (#340).

  Two owner rulings during the 2026-07-30 campaign asked for the same thing: a
  repair of bad production data should be a *reviewed operation*, not a `psql`
  session. #339 built the mechanism; this is the surface that makes it something
  the owner can actually reach on a running stack, where there is no shell and
  no `mix`.

  It is deliberately two verbs and no more:

    * `index` shows every registered correction with its scope, its
      reversibility, and — the point of the whole thing — the rows it *would*
      change right now. It writes nothing. Dry-run is not a mode you opt into
      here; it is what a GET means.
    * `apply` runs one named correction, and requires a `reason`.

  ## What this surface cannot do

  `:name` resolves through `Stacks.DataCorrection.Registry.fetch/1`, so the only
  rows reachable over HTTP are the ones a reviewed, committed correction module
  already claims. There is no table parameter, no column parameter and no
  predicate parameter, and adding one would turn a repair tool into the arbitrary
  SQL endpoint `issues/138-prod-data-access-break-glass.md` rules out in as many
  words. An unregistered name is a 404, not an error to work around.

  ## Authorisation

  The router puts this behind `:admin` (MFA-verified admin session) *and*
  `:require_owner`, which re-checks the role on the loaded user at the point of
  use. The admin login already refuses a non-owner, so the second check looks
  redundant — it is not. An admin token outlives the role it was minted under:
  demote the account and the pipeline happily keeps loading the user for the
  remaining life of the session. For a read that is unfortunate; for a mutation
  that rewrites production rows it is the difference between a stale token and a
  stale token that can still write. Checking where the write happens, rather than
  only where the session began, is the lesson #332 recorded.
  """

  use CoreWeb, :controller

  alias Stacks.DataCorrection
  alias Stacks.DataCorrection.Registry

  @doc """
  GET /api/admin/data_corrections

  Every registered correction and its current blast radius. Writes nothing.
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    {:ok, outcomes} = DataCorrection.run_all(Registry.all())

    conn
    |> assign(:audit_row_count, Enum.sum(Enum.map(outcomes, & &1.count)))
    |> json(%{corrections: Enum.map(outcomes, &render_outcome/1)})
  end

  @doc """
  POST /api/admin/data_corrections/:name/apply

  Applies one correction. `reason` is required and is recorded verbatim in the
  audit row for every changed row, in the same transaction as the change.
  """
  @spec apply(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def apply(conn, %{"name" => name} = params) do
    reason = params |> Map.get("reason", "") |> to_string() |> String.trim()

    with {:reason, true} <- {:reason, reason != ""},
         {:ok, correction} <- Registry.fetch(name) do
      run(conn, correction, reason)
    else
      {:reason, false} ->
        conn |> put_status(422) |> json(%{error: "reason_required"})

      :error ->
        conn |> put_status(404) |> json(%{error: "unknown_correction"})
    end
  end

  defp run(conn, correction, reason) do
    result =
      DataCorrection.run(correction,
        apply: true,
        invoked_by: "admin api",
        actor_id: conn.assigns.current_user.id,
        reason: reason
      )

    case result do
      {:ok, outcome} ->
        conn
        |> assign(:audit_row_count, outcome.count)
        |> json(%{correction: render_outcome(outcome)})

      # Nothing was committed — not this row's change, not any earlier row's.
      # Surfacing the reason verbatim is the point: a repair that collides with
      # real data is a decision for the operator, and they cannot make it from
      # a generic failure.
      {:error, reason} ->
        conn
        |> assign(:audit_row_count, 0)
        |> put_status(422)
        |> json(%{error: "correction_failed", detail: inspect(reason)})
    end
  end

  defp render_outcome(outcome) do
    {disposition, note} = outcome.reversibility

    %{
      name: outcome.correction,
      scope: outcome.scope,
      reversibility: Atom.to_string(disposition),
      reversibility_note: note,
      mode: Atom.to_string(outcome.mode),
      count: outcome.count,
      changes: Enum.map(outcome.changes, &Map.take(&1, [:id, :from, :to, :because])),
      report: outcome.report
    }
  end
end
