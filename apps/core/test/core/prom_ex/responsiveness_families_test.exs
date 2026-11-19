defmodule Core.PromEx.ResponsivenessFamiliesTest do
  @moduledoc """
      The two families the ruled responsiveness thresholds read:

      - `stacks_upload_phase_stop_duration_milliseconds` — the upload phase
        span fired for every identification and reached NO store (the same
        declared-but-unreported shape the six money families had), so
        time-to-answer was unmeasurable in production.
      - `stacks_upload_ack_duration_milliseconds` — time to the stream's first
        SSE event; the acknowledgement bound (< 1s).

      The bar matches `unreported_families_test.exs`: emit the REAL event and
      read the REAL scrape — a declaration without a value coming back is the
      exact failure these exist to prevent.
  """

  use ExUnit.Case, async: false

  defp scrape do
    Process.sleep(50)
    output = PromEx.get_metrics(Core.PromEx)
    refute output == :prom_ex_down, "Core.PromEx must be running for this test"
    output
  end

  defp native_ms(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  defp family_count(scrape_output, family, match) do
    scrape_output
    |> String.split("\n")
    |> Enum.filter(&(String.starts_with?(&1, family <> "_count") and &1 =~ match))
    |> Enum.map(fn line -> line |> String.split() |> List.last() |> String.to_integer() end)
    |> Enum.sum()
  end

  test "an identify_book phase stop reaches the scrape as a labelled duration" do
    family = "stacks_upload_phase_stop_duration_milliseconds"
    before = family_count(scrape(), family, ~s(phase="identify_book"))

    :telemetry.execute(
      [:stacks, :upload, :phase, :stop],
      %{duration: native_ms(4_321)},
      %{phase: :identify_book, upload_id: Ecto.UUID.generate()}
    )

    after_count = family_count(scrape(), family, ~s(phase="identify_book"))

    # ⬛ A value CAME BACK, attributed to the phase the thresholds will filter
    # on — not merely a declaration in the plugin.
    assert after_count == before + 1
  end

  test "an acknowledgement emit reaches the scrape" do
    family = "stacks_upload_ack_duration_milliseconds"
    before = family_count(scrape(), family, "")

    :telemetry.execute([:stacks, :upload, :ack], %{duration: native_ms(42)}, %{})

    assert family_count(scrape(), family, "") == before + 1
  end
end
