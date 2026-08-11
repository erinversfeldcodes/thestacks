defmodule Stacks.DataCorrection.Registry do
  @moduledoc """
      The corrections the mix task, `Release.correct_data/1` and the admin
      endpoint run, in order. An explicit list, not a module scan: what is live
      and in what order is read in one place — and it is the SECURITY BOUNDARY:
      the admin endpoint resolves `:name` through `fetch/1`, so the rows
      reachable over HTTP are exactly what was written down and reviewed here.
      No endpoint takes a table+column, and adding one would undo that.
      Corrections stay registered after being applied everywhere — idempotence
      costs one SELECT and buys repair of restored backups and re-branched
      databases. Targeted (parameterised) corrections live in `targeted/0`,
      runnable only with operator-named rows, never on the deploy path.
  """

  alias Stacks.DataCorrection.{
    NormaliseEditionIsbn10,
    SeedEditionVerificationSource,
    StaleSeedEditionIsbn,
    UnmergeEdition
  }

  @corrections [
    NormaliseEditionIsbn10,
    StaleSeedEditionIsbn,
    SeedEditionVerificationSource
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
