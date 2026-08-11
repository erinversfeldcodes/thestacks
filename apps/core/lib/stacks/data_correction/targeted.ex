defmodule Stacks.DataCorrection.Targeted do
  @moduledoc """
  A correction over rows the operator NAMES, rather than a standing
  predicate's matches — the parameterised sibling `Registry` said un-merge
  would need (340). Everything that makes a correction trustworthy is
  shared, not reimplemented: `run_targeted/3` plans via `c:plan/1` (which
  may refuse the argument), then hands off to the same `apply_plan/4` —
  same transaction, same audit row, same rollback. Targeted corrections
  never run on the deploy path; an operator names rows or nothing runs.
  """

  @doc "Stable identifier, e.g. `\"unmerge_edition\"`. Resolved through the registry."
  @callback name() :: String.t()

  @doc "`audit.audit_log.resource_type` for the rows this correction touches."
  @callback resource_type() :: String.t()

  @doc """
  One sentence naming exactly which rows *this argument* claims.

  Computed rather than constant: a targeted correction's blast radius is a
  property of what it was pointed at.
  """
  @callback scope(argument :: term()) :: String.t()

  @doc """
  Whether the change can be undone, and what an undo could not restore.

  Constant, like the parameter-free callback: reversibility is a property of
  the operation, not of the row it lands on.
  """
  @callback reversibility() :: Stacks.DataCorrection.reversibility()

  @doc """
  Turns a caller-supplied params map into this correction's own argument term.

  The correction names the keys it accepts. A key it does not name is not
  ignored-but-carried, it simply never becomes part of the argument — which is
  what keeps an HTTP body from reaching a write path.
  """
  @callback cast_argument(params :: map()) :: {:ok, term()} | {:error, term()}

  @doc """
  The rows this argument would change, and what they would become — or a reason
  the argument cannot be honoured.
  """
  @callback plan(argument :: term()) ::
              {:ok, [Stacks.DataCorrection.change()]} | {:error, term()}

  @doc """
  Applies one change.

  Must be conditional on the row still holding `:from`. May return
  `{:ok, detail}` to put what it actually did — an id it minted, a count it
  observed — into the audit row beside the planned change.
  """
  @callback apply_change(Stacks.DataCorrection.change()) ::
              :ok | {:ok, map()} | {:error, term()}
end
