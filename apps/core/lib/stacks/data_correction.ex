defmodule Stacks.DataCorrection do
  @moduledoc """
  Repairing bad data as a named operation instead of a one-off `UPDATE`.

  Issue #339 found rows in production and staging that violate an invariant the
  application has always claimed to hold. Fixing them by hand — a `psql`
  session, or an inline `UPDATE` buried in a migration — would have left no
  record of what changed, no way to see the blast radius first, and nothing to
  reuse the next time. The owner's ruling was to build the repair as something
  that outlives its first use, so this module is the shape every future
  correction takes:

    * **dry-run by default.** `run/2` reports what it *would* change and touches
      nothing unless the caller passes `apply: true`. Seeing the rows before
      moving them is the whole point.
    * **idempotent.** A correction's `c:plan/0` selects only rows that still
      need changing, so the second run is empty by construction rather than by
      the caller remembering not to run it twice.
    * **audited.** Every applied change writes an `audit.audit_log` row naming
      the correction, the row, the old value, the new value, the reason, and
      who invoked it. The audit write is inside the same transaction as the
      change: a correction that cannot be recorded does not happen.
    * **scoped by an explicit predicate.** A correction says in `c:scope/0`
      exactly which rows it claims, and `c:plan/0` must implement that and
      nothing wider. "Fix everything that looks wrong" is how a repair becomes
      the next incident.
    * **honest about reversal.** `c:reversibility/0` states whether the change
      can be undone and what an undo could not restore. Most corrections are
      one-way, and the moment to say so is before the run, not after.

  ## Running one

      # from apps/core, against the configured DB
      mix stacks.data.correct                 # dry-run every correction
      mix stacks.data.correct --apply         # apply them

      # against a deployed stack (no mix in a release)
      /app/bin/core eval 'Stacks.Release.correct_data()'

      # as the platform owner, against a running stack (#340)
      GET  /api/admin/data_corrections              # blast radius, writes nothing
      POST /api/admin/data_corrections/:name/apply  # requires a reason

  `docs/runbooks/data-correction.md` is the operator-facing walkthrough.

  ## Writing one

  Implement the five callbacks. Reach the rows through
  `Stacks.DataCorrection.Column` rather than an Ecto schema: a correction is
  usually run precisely because reality and the schema disagree, and the
  changeset that normalises the bad value away is how a repair quietly becomes
  a no-op. Then add the module to `Stacks.DataCorrection.Registry`, which is
  the only way anything can name it.

  ## Deliberately not a framework

  There is no scheduler and no generic "edit any row" path — not in the mix
  task, not in the release entry point, and not in the admin API, whose `:name`
  parameter resolves through the registry and can therefore only ever reach a
  correction someone wrote down. Adding a correction is a code change that gets
  reviewed like one; that is the point, and it is why there is no endpoint that
  takes a table, a column and a value.
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
  """
  @callback apply_change(Stacks.DataCorrection.change()) :: :ok | {:error, term()}

  @audit_action "data.correction.applied"

  @doc """
  Plans `correction`, and applies it only when `apply: true` is passed.

  ## Options

    * `:apply` — write the changes (default `false`, i.e. dry-run)
    * `:invoked_by` — free text naming the entry point, e.g.
      `"mix stacks.data.correct"` (default `"unknown"`)
    * `:actor_id` — the user id of the human who asked for this, when there is
      one. `nil` for the deploy path, which no human invokes directly.
    * `:reason` — the operator's justification for *this* run, distinct from
      the per-row `:because` the correction itself supplies.

  Returns `{:ok, outcome}`, or `{:error, {row_id, reason}}` when a change or
  its audit write failed — in which case nothing was committed.
  """
  @spec run(module(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def run(correction, opts \\ []) do
    plan = correction.plan()

    if Keyword.get(opts, :apply, false) do
      apply_plan(correction, plan, opts)
    else
      {:ok, outcome(correction, :dry_run, plan)}
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

  # Nothing to do is the steady state, and it must not open a transaction or
  # start a vault just to discover that.
  defp apply_plan(correction, [], _opts),
    do: {:ok, outcome(correction, :applied, [])}

  defp apply_plan(correction, plan, opts) do
    ensure_vault!()

    Repo.transaction(fn ->
      Enum.each(plan, &apply_and_audit(correction, &1, opts))
    end)
    |> case do
      {:ok, _} -> {:ok, outcome(correction, :applied, plan)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The audit write shares the change's transaction on purpose: a correction
  # that cannot be recorded is rolled back rather than applied silently. An
  # unexplained mutation is worse than an unrepaired row — the row is at least
  # still describable.
  defp apply_and_audit(correction, change, opts) do
    with :ok <- correction.apply_change(change),
         {:ok, _entry} <- audit(correction, change, opts) do
      :ok
    else
      {:error, reason} -> Repo.rollback({change.id, reason})
    end
  end

  defp audit(correction, change, opts) do
    Audit.log(Keyword.get(opts, :actor_id), @audit_action,
      resource_type: correction.resource_type(),
      resource_id: change.id,
      metadata: %{
        correction: correction.name(),
        scope: correction.scope(),
        reversibility: reversibility_text(correction),
        from: change.from,
        to: change.to,
        because: change.because,
        invoked_by: Keyword.get(opts, :invoked_by, "unknown"),
        reason: Keyword.get(opts, :reason)
      }
    )
  end

  # `Stacks.Audit` encrypts its metadata through the Cloak vault, which lives in
  # `Core.Application`'s supervision tree. A correction run from `mix` or from
  # `bin/core eval` has a started repo but no application tree, and
  # `Audit.log/3` rescues its own failures — so without this the audit trail
  # would silently be empty in exactly the situation it exists for.
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

  defp outcome(correction, mode, changes) do
    %{
      correction: correction.name(),
      scope: correction.scope(),
      reversibility: correction.reversibility(),
      mode: mode,
      changes: changes,
      count: length(changes),
      report: report(correction, mode, changes)
    }
  end

  defp reversibility_text(correction) do
    case correction.reversibility() do
      {:one_way, why} -> "one-way: #{why}"
      {:reversible, how} -> "reversible: #{how}"
    end
  end

  @doc false
  @spec report(module(), :dry_run | :applied, [change()]) :: String.t()
  def report(correction, mode, changes) do
    header = [
      "data-correction: #{correction.name()} (#{mode})",
      "  scope: #{correction.scope()}",
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
