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

  The mechanism carries no generic "edit any row" path, by design.
  """

  alias Stacks.DataCorrection.{NormaliseEditionIsbn10, StaleSeedEditionIsbn}

  @corrections [
    NormaliseEditionIsbn10,
    StaleSeedEditionIsbn
  ]

  @doc "Every registered correction, in run order."
  @spec all() :: [module()]
  def all, do: @corrections

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
end
