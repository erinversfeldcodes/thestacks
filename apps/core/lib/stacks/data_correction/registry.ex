defmodule Stacks.DataCorrection.Registry do
  @moduledoc """
  The corrections `mix stacks.data.correct` and `Stacks.Release.correct_data/1`
  run, in order.

  An explicit list rather than a module scan: which repairs are live, and in
  which order, is a decision to read in one place — not something inferred from
  what happens to be compiled.

  A correction stays here after it has been applied everywhere. It is
  idempotent, so leaving it costs one `SELECT` and buys a standing guarantee
  that a restored backup or a re-branched database gets repaired too.
  """

  alias Stacks.DataCorrection.{NormaliseEditionIsbn10, StaleSeedEditionIsbn}

  @corrections [
    NormaliseEditionIsbn10,
    StaleSeedEditionIsbn
  ]

  @doc "Every registered correction, in run order."
  @spec all() :: [module()]
  def all, do: @corrections
end
