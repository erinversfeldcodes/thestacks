defmodule StacksWeb.DataCorrectionController do
  @moduledoc """
      The platform owner's HTTP surface for `Stacks.DataCorrection` —
      a repair should be a reviewed operation, not a `psql` session, and a
      running stack has no shell. Three verbs, no more: `index` (every
      registered correction + the rows it WOULD change — a GET means dry-run),
      `apply` (one named correction, `reason` required), `target` (one named
      targeted correction against operator-named rows, `reason` required).
      `:name` resolves through `Registry.fetch/1`, so the reachable set is
      exactly the reviewed list — no endpoint takes a table or column. Owner
      role enforced by `:require_owner` AFTER `:admin` (a demoted admin token
      must not reach this).
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

  @doc """
      POST /api/admin/data_corrections/:name/target

      Runs one targeted correction against the rows named in `argument`.
      `reason` is required. `apply` defaults to `false` — a dry-run that reports the
      blast radius and writes nothing.
  """
  @spec target(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def target(conn, %{"name" => name} = params) do
    reason = params |> Map.get("reason", "") |> to_string() |> String.trim()
    argument_params = params |> Map.get("argument") |> argument_map()

    with {:reason, true} <- {:reason, reason != ""},
         {:registry, {:ok, correction}} <- {:registry, Registry.fetch_targeted(name)},
         {:argument, {:ok, argument}} <- {:argument, correction.cast_argument(argument_params)} do
      run_targeted(conn, correction, argument, reason, params["apply"] == true)
    else
      {:reason, false} ->
        conn |> put_status(422) |> json(%{error: "reason_required"})

      {:registry, :error} ->
        conn |> put_status(404) |> json(%{error: "unknown_correction"})

      {:argument, {:error, detail}} ->
        conn |> put_status(422) |> json(%{error: "invalid_argument", detail: inspect(detail)})
    end
  end

  defp argument_map(argument) when is_map(argument), do: argument
  defp argument_map(_), do: %{}

  defp run_targeted(conn, correction, argument, reason, apply?) do
    correction
    |> DataCorrection.run_targeted(argument,
      apply: apply?,
      invoked_by: "admin api",
      actor_id: conn.assigns.current_user.id,
      reason: reason
    )
    |> respond(conn, apply?)
  end

  defp respond({:ok, outcome}, conn, apply?) do
    conn
    |> assign(:audit_row_count, if(apply?, do: outcome.count, else: 0))
    |> json(%{correction: render_outcome(outcome)})
  end

  defp respond({:error, reason}, conn, _apply?) do
    conn
    |> assign(:audit_row_count, 0)
    |> put_status(422)
    |> json(%{error: "correction_failed", detail: inspect(reason)})
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
