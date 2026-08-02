defmodule Stacks.DataCorrection.Registry do
  @moduledoc """
  The corrections `mix stacks.data.correct`, `Stacks.Release.correct_data/1` and
  `POST /api/admin/data_corrections/:name/apply` run, in order.

  An explicit list rather than a module scan: which repairs are live, and in
  which order, is a decision to read in one place — not something inferred from
  what happens to be compiled. It is also the security boundary. The admin
  endpoint resolves its `:name` parameter through `fetch/1`, so the set of rows
  the platform owner can reach over HTTP is exactly the set someone wrote down
  here and had reviewed. There is no endpoint that takes a table and a column,
  and adding one would undo the property this list exists to hold.

  A correction stays here after it has been applied everywhere. It is
  idempotent, so leaving it costs one `SELECT` and buys a standing guarantee
  that a restored backup or a re-branched database gets repaired too.

  ## What is registered, and what deliberately is not (#340)

  | Correction | Why it is here |
  |---|---|
  | `NormaliseEditionIsbn10` | #339: editions holding an ISBN-10 in a column that has always meant ISBN-13. |
  | `StaleSeedEditionIsbn` | #339: three seed fixtures still holding their pre-#335 literal. |

  Two candidates were surveyed and excluded, each for a reason that is a
  property of the *repair*, not of the mechanism:

    * **The resolver-identifier backfill (#346).** `plan/0` runs inside
      `fly deploy` via `Stacks.Release.deploy/0`, and this repair needs an Open
      Library round-trip per row — which would put a third-party outage in the
      path of every deploy and would never converge for a permanently
      unresolvable ISBN. Re-enqueuing `EnrichBookJob` is the right vehicle; a
      correction whose value has to be fetched rather than derived does not
      belong here.
    * **Un-merge (#317 item 7c).** Takes an argument — *which* two works — so it
      is a targeted operation rather than a standing repair, and a `plan/0`
      that takes no arguments cannot express it. It reuses this mechanism's
      write path (`Stacks.DataCorrection.Column`) and its audit contract; when
      it lands it will need a parameterised sibling to `run/2`, not a second
      mechanism.

  #376 built that sibling rather than a second mechanism, so the second
  exclusion is now a second list — see below. The first stands: the
  resolver-identifier backfill is still `EnrichBookJob`'s job.

  The mechanism carries no generic "edit any row" path, by design.

  ## The targeted list (#376)

  `Stacks.DataCorrection.Targeted` corrections repair the rows an operator
  *names*. They are listed separately from `all/0` because they must never run
  unattended: `mix stacks.data.correct` and `Stacks.Release.correct_data/1`
  sweep `all/0` on every deploy, and a repair that goes where it is pointed has
  no business being pointed by a deploy.

  | Targeted correction | Argument |
  |---|---|
  | `UnmergeEdition` | the edition to split out, and the title of the work it becomes |

  `fetch_targeted/1` is the same security boundary `fetch/1` is, and for a
  sharper reason: a targeted correction writes where it is aimed, so being more
  powerful than a standing one is exactly why it may not also be more reachable.
  """

  alias Stacks.DataCorrection.{NormaliseEditionIsbn10, StaleSeedEditionIsbn, UnmergeEdition}

  @corrections [
    NormaliseEditionIsbn10,
    StaleSeedEditionIsbn
  ]

  @targeted [
    UnmergeEdition
  ]

  @doc "Every registered correction, in run order."
  @spec all() :: [module()]
  def all, do: @corrections

  @doc """
  Every registered `Stacks.DataCorrection.Targeted` correction.

  Deliberately not folded into `all/0`: the deploy path and the mix task sweep
  `all/0`, and a correction that needs an argument has none to sweep with.
  """
  @spec all_targeted() :: [module()]
  def all_targeted, do: @targeted

  @doc """
  The correction registered under `name`, or `:error`.

  The only way to turn a caller-supplied string into a correction module — so
  an unregistered name reaches nothing rather than raising `ArgumentError` on
  `String.to_existing_atom/1` or, worse, resolving to some other module.
  """
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name) when is_binary(name) do
    case Enum.find(@corrections, &(&1.name() == name)) do
      nil -> :error
      correction -> {:ok, correction}
    end
  end

  @doc """
  The targeted correction registered under `name`, or `:error`.

  Separate from `fetch/1` rather than a union of the two lists, so a name
  belonging to a standing correction cannot be run through the targeted verb
  (or the reverse) — the two take different arguments and mean different things,
  and a lookup that quietly crosses between them is how an operator ends up
  applying something other than what they named.
  """
  @spec fetch_targeted(String.t()) :: {:ok, module()} | :error
  def fetch_targeted(name) when is_binary(name) do
    case Enum.find(@targeted, &(&1.name() == name)) do
      nil -> :error
      correction -> {:ok, correction}
    end
  end
end
