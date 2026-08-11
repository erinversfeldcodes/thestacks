defmodule Stacks.DataCorrection do
  @moduledoc """
      Repairing bad data as a named, reusable operation instead of a one-off
      `UPDATE`. Every correction is: dry-run by default (`run/2`
      reports; writes only with `apply: true`), idempotent (`c:plan/0` selects
      only rows still needing change), audited (each change writes an
      `audit.audit_log` row in the SAME transaction — no audit, no change), and
      registered in `Registry` so the deploy path runs the full set. See
      `Stacks.DataCorrection.Column` for the common single-column shape.
  """

  alias Core.Repo
  alias Stacks.Audit

  @typedoc """
    One row's worth of correction.

    `:id` is the row's primary key as a string, `:from`/`:to` the old and new
    values of whatever the correction changes, and `:because` the human reason
    that lands in the audit trail.
  """
  @type change :: %{
          required(:id) => String.t(),
          required(:from) => term(),
          required(:to) => term(),
          required(:because) => String.t()
        }

  @typedoc """
    Whether the change can be undone, and the sentence that says what an undo
    would and would not restore.

    `{:one_way, why}` is the common case and the honest one: the value being
    replaced was wrong, so nothing should ever put it back. The audit row keeps
    it if the history is ever needed.
  """
  @type reversibility :: {:one_way, String.t()} | {:reversible, String.t()}

  @type outcome :: %{
          correction: String.t(),
          scope: String.t(),
          reversibility: reversibility(),
          mode: :dry_run | :applied,
          changes: [change()],
          count: non_neg_integer(),
          report: String.t()
        }

  @doc "Stable identifier for this correction, e.g. `\"normalise_edition_isbn10\"`."
  @callback name() :: String.t()

  @doc "`audit.audit_log.resource_type` for the rows this correction touches."
  @callback resource_type() :: String.t()

  @doc "One sentence naming exactly which rows are in scope."
  @callback scope() :: String.t()

  @doc """
      Whether this correction can be undone, and what an undo could not restore.

      Stated up front and printed in the report, because "can I put it back?" is
      the question the operator asks *after* running it, and by then the answer has
      to already be written down.
  """
  @callback reversibility() :: Stacks.DataCorrection.reversibility()

  @doc """
      The rows that still need correcting, and what they would become.

      Must return `[]` once the correction has been applied — that is what makes
      `run/2` idempotent.
  """
  @callback plan() :: [Stacks.DataCorrection.change()]

  @doc """
      Applies one change.

      Must be conditional on the row still holding `:from`, so a row that moved
      between planning and applying is refused rather than overwritten.

      `{:ok, detail}` is for a correction that *learns* something by applying —
      un-merge mints the work the edition moves onto, so the destination id
      does not exist at planning time. `detail` is merged into the audit row beside
      the planned change, which is the only way the trail can say where the row
      actually went. A plain `:ok` means "exactly what the plan said", and every
      /correction returns that.
  """
  @callback apply_change(Stacks.DataCorrection.change()) ::
              :ok | {:ok, map()} | {:error, term()}

  @audit_action "data.correction.applied"

  @doc """
      Plans `correction`; applies only with `apply: true`. Options: `:apply`
      (default false = dry-run), `:invoked_by` (entry-point label), `:actor_id`
      (nil for the deploy path), `:reason` (this run's justification, distinct
      from the correction's per-row `:because`). Returns `{:ok, outcome}` or
      `{:error, {row_id, reason}}` — in which case nothing was committed.
  """
  @spec run(module(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def run(correction, opts \\ []) do
    plan = correction.plan()

    if Keyword.get(opts, :apply, false) do
      apply_plan(correction, correction.scope(), plan, opts)
    else
      {:ok, outcome(correction, correction.scope(), :dry_run, plan)}
    end
  end

  @doc """
      `run/2` for a `Targeted` correction — repairs the rows the operator NAMES
      rather than a standing predicate's matches. After planning it is the
      parameter-free path verbatim (same transaction, audit, rollback); only
      planning takes the argument. Dry-run default; `{:error, reason}` without a
      transaction when `c:Targeted.plan/1` refuses the argument. Same options
      as `run/2`.
  """
  @spec run_targeted(module(), term(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def run_targeted(correction, argument, opts \\ []) do
    with {:ok, plan} <- correction.plan(argument) do
      scope = correction.scope(argument)

      if Keyword.get(opts, :apply, false) do
        apply_plan(correction, scope, plan, opts)
      else
        {:ok, outcome(correction, scope, :dry_run, plan)}
      end
    end
  end

  @doc """
      Runs several corrections in order, returning `{:ok, outcomes}` or the first
      `{:error, _}`. Each correction is its own transaction: an earlier one that
      succeeded stays applied and stays audited.
  """
  @spec run_all([module()], keyword()) :: {:ok, [outcome()]} | {:error, term()}
  def run_all(corrections, opts \\ []) do
    Enum.reduce_while(corrections, {:ok, []}, fn correction, {:ok, acc} ->
      case run(correction, opts) do
        {:ok, outcome} -> {:cont, {:ok, acc ++ [outcome]}}
        {:error, reason} -> {:halt, {:error, {correction, reason}}}
      end
    end)
  end

  defp apply_plan(correction, scope, [], _opts),
    do: {:ok, outcome(correction, scope, :applied, [])}

  defp apply_plan(correction, scope, plan, opts) do
    ensure_vault!()

    Repo.transaction(fn ->
      Enum.each(plan, &apply_and_audit(correction, scope, &1, opts))
    end)
    |> case do
      {:ok, _} -> {:ok, outcome(correction, scope, :applied, plan)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_and_audit(correction, scope, change, opts) do
    with {:ok, detail} <- applied_detail(correction.apply_change(change)),
         {:ok, _entry} <- audit(correction, scope, change, detail, opts) do
      :ok
    else
      {:error, reason} -> Repo.rollback({change.id, reason})
    end
  end

  defp applied_detail(:ok), do: {:ok, %{}}
  defp applied_detail({:ok, detail}) when is_map(detail), do: {:ok, detail}
  defp applied_detail({:error, reason}), do: {:error, reason}

  defp audit(correction, scope, change, detail, opts) do
    Audit.log(Keyword.get(opts, :actor_id), @audit_action,
      resource_type: correction.resource_type(),
      resource_id: change.id,
      metadata:
        Map.merge(detail, %{
          correction: correction.name(),
          scope: scope,
          reversibility: reversibility_text(correction),
          from: change.from,
          to: change.to,
          because: change.because,
          invoked_by: Keyword.get(opts, :invoked_by, "unknown"),
          reason: Keyword.get(opts, :reason)
        })
    )
  end

  defp ensure_vault! do
    case Process.whereis(Stacks.Vault) do
      nil ->
        case Stacks.Vault.start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "could not start Stacks.Vault to audit: #{inspect(reason)}"
        end

      _pid ->
        :ok
    end
  end

  defp outcome(correction, scope, mode, changes) do
    %{
      correction: correction.name(),
      scope: scope,
      reversibility: correction.reversibility(),
      mode: mode,
      changes: changes,
      count: length(changes),
      report: report(correction, scope, mode, changes)
    }
  end

  defp reversibility_text(correction) do
    case correction.reversibility() do
      {:one_way, why} -> "one-way: #{why}"
      {:reversible, how} -> "reversible: #{how}"
    end
  end

  @doc false
  @spec report(module(), String.t(), :dry_run | :applied, [change()]) :: String.t()
  def report(correction, scope, mode, changes) do
    header = [
      "data-correction: #{correction.name()} (#{mode})",
      "  scope: #{scope}",
      "  #{reversibility_text(correction)}",
      "  rows:  #{length(changes)}"
    ]

    body =
      Enum.map(changes, fn change ->
        "  - #{change.id}: #{inspect(change.from)} -> #{inspect(change.to)}  (#{change.because})"
      end)

    footer =
      case {mode, changes} do
        {:dry_run, []} -> ["  nothing to correct"]
        {:dry_run, _} -> ["  DRY RUN — nothing was written. Re-run with --apply to write."]
        {:applied, []} -> ["  nothing to correct"]
        {:applied, _} -> ["  applied and audited"]
      end

    Enum.join(header ++ body ++ footer, "\n")
  end
end
