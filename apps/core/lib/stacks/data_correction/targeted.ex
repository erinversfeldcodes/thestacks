defmodule Stacks.DataCorrection.Targeted do
  @moduledoc """
  A correction over rows the operator *names*, rather than every row a standing
  predicate matches.

  #340 surveyed un-merge as a candidate `Stacks.DataCorrection` and excluded it,
  for a reason about the shape rather than the repair: un-merge takes an
  argument — which edition, and what the work it becomes is called — and a
  `c:Stacks.DataCorrection.plan/0` that takes none cannot express it.
  `Stacks.DataCorrection.Registry` wrote the conclusion down in as many words:
  *"it will need a parameterised sibling to `run/2`, not a second mechanism."*

  This is that sibling's half of the contract. Everything that made a
  `Stacks.DataCorrection` trustworthy is shared rather than reimplemented:
  `Stacks.DataCorrection.run_targeted/3` plans, then hands the plan to the same
  private `apply_plan/4` the parameter-free path uses — so it is the same
  transaction, the same `audit.audit_log` row, and the same rollback when the
  audit cannot be written. There is one audit path, and this did not add a
  second.

  The three differences are all consequences of taking an argument:

    * **`c:plan/1` may refuse.** A standing correction's predicate cannot be
      wrong; an argument can name a row that does not exist, or one it would be
      a mistake to touch. `{:error, reason}` — returned before anything opens a
      transaction — is how it says so, and the operator sees the reason rather
      than an empty plan they have to interpret.
    * **`c:scope/1` is computed.** "Which rows does this claim?" has no answer
      until the argument is known, and the scope is what the audit row and the
      dry-run report quote.
    * **`c:cast_argument/1` exists at all.** The argument arrives as a JSON
      object on an HTTP request. `Stacks.Books.merge_edition/2` keeps a
      deliberately narrow set of caller-supplied fields precisely because
      `StacksWeb.BookController.merge_format/2` hands it the raw request params
      — and the inverse of an operation must not be looser than the operation.
      So the *correction* names the keys it accepts and turns them into its own
      term; no params map ever reaches a write path.

  ## Idempotence is not claimed here, and that is deliberate

  A standing correction is idempotent by construction: its `plan/0` stops
  selecting the row once the row is fixed. A targeted one is aimed at a row a
  human picked, so running it twice means a human asked twice, and there is no
  predicate that could tell the difference. What stops the second run from
  compounding is `Stacks.DataCorrection.Column.swap/4`'s "the row must still
  hold `from`" clause: the second attempt finds the row has moved and returns
  `{:error, {:row_no_longer_matches, ...}}` rather than writing again.

  ## Still not a framework

  `Stacks.DataCorrection.Registry.fetch_targeted/1` is the only way to turn a
  caller-supplied string into one of these, and it is an explicit list — the
  same security boundary the parameter-free registry is. A targeted correction
  is more powerful than a standing one (it writes where it is pointed), which
  is the reason it may not also be more reachable.
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
