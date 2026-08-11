defmodule Stacks.Duration do
  @moduledoc """
    The one place a configured `{n, unit}` duration becomes seconds. Three
    call sites each had a private `unit_in_seconds/1`, two with comments
    promising they mirrored each other; the third handled only
    second/minute/hour, so a `{1,:day}` rotation grace fell to its catch-all
    and was honoured as ONE SECOND — a silent 86,400× error in a security
    window. A duplicated table drifts, and a comment saying it doesn't is
    worth nothing.
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
    Convert a `{count, unit}` duration to whole seconds. Singular and plural
    unit atoms both accepted (config is written both ways). An unknown unit is
    honoured as seconds and logged, never raised (covered in
    `Stacks.DurationTest` under `capture_log/1`).

        iex> Stacks.Duration.to_seconds({7,:day})
        604800

        iex> Stacks.Duration.to_seconds({30,:minutes})
        1800
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
