defmodule Stacks.Duration do
  @moduledoc """
  The one place a `{n, unit}` configured duration becomes a number of seconds.

  ## Why this exists

  Three call sites converted `{n, unit}` by hand, each with its own private
  `unit_in_seconds/1`:

    * `StacksWeb.AuthController` — `:session_absolute_cap`
    * `Stacks.Workers.GuardianTokenSweepJob` — the same `:session_absolute_cap`,
      with a comment promising it "mirrors AuthController's `{n, unit}` config
      shape so the two never disagree"
    * `Stacks.Accounts` — `:session_rotation_grace`, with a comment promising it
      "mirrors the AuthController session-cap `unit_in_seconds/1`"

  Two of those three promises were kept. The third was not: `Stacks.Accounts`
  handled `:second`, `:minute` and `:hour` **and nothing else**, so a
  `session_rotation_grace` of `{1, :day}` fell through to its catch-all and was
  honoured as **one second** — a silent 86,400× error in a security window, on
  the one copy whose comment claimed it matched the others. That is the argument
  for this module: a duplicated table drifts, and a comment saying it does not
  is worth nothing.

  ## Unknown units

  An unrecognised unit is a misconfiguration, and every caller here is a
  *security window* — a session cap, a token-rotation grace period. So the
  fail-safe direction is unambiguous: treat the unknown unit as **seconds**, the
  smallest window we offer, and the window fails **shorter** (more secure)
  rather than longer.

  It must not raise. These conversions run inside the authenticated-request
  verify gate and inside a background sweep; raising would turn a typo in config
  into an auth outage or a silently dead job. It is logged and counted instead,
  so "misconfigured" is visible without being fatal.
  """

  require Logger

  @units %{
    second: 1,
    seconds: 1,
    minute: 60,
    minutes: 60,
    hour: 3_600,
    hours: 3_600,
    day: 86_400,
    days: 86_400,
    week: 604_800,
    weeks: 604_800
  }

  @doc """
  Convert a `{count, unit}` duration to whole seconds.

  Singular and plural unit atoms are both accepted, because config in this repo
  is written both ways (`{8, :hours}` for Guardian's TTL, `{7, :day}` for the
  session cap) and a reader should not have to remember which spelling a given
  key wants.

      iex> Stacks.Duration.to_seconds({7, :day})
      604800

      iex> Stacks.Duration.to_seconds({20, :second})
      20

      iex> Stacks.Duration.to_seconds({30, :minutes})
      1800

  An unknown unit is honoured as seconds (see the module doc) and logged, never
  raised — covered by `Stacks.DurationTest` rather than a doctest, because the
  warning is part of the behaviour and belongs under `capture_log/1`.
  """
  @spec to_seconds({integer(), atom()}) :: integer()
  def to_seconds({count, unit}) when is_integer(count) and is_atom(unit) do
    count * unit_in_seconds(unit)
  end

  defp unit_in_seconds(unit) do
    case Map.fetch(@units, unit) do
      {:ok, seconds} ->
        seconds

      :error ->
        Logger.warning(
          "Stacks.Duration: unknown duration unit #{inspect(unit)} — honouring it as seconds. " <>
            "Known units: #{@units |> Map.keys() |> Enum.sort() |> inspect()}"
        )

        :telemetry.execute([:stacks, :duration, :unknown_unit], %{count: 1}, %{unit: unit})

        1
    end
  end
end
