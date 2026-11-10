defmodule Stacks.AI.GpuWindowTest do
  use ExUnit.Case, async: true

  alias Stacks.AI.GpuWindow

  describe "the idle tail is counted once per container, not once per request" do
    test "a container that served one image still bills its whole tail" do
      # ⛔ THE DEFECT THIS MODULE EXISTS TO PREVENT. One request, observed at an
      # age of 2s, on a container that then idles out its window. Summing
      # observed ages gives 2 seconds; the machine billed 302.
      assert GpuWindow.billed_seconds([{"c1", 2.0}]) == 302.0
    end

    test "many requests on one container add the tail only once" do
      observations = [{"c1", 2.0}, {"c1", 40.0}, {"c1", 120.0}]

      # ⬛ The maximum age, plus ONE tail. Adding a tail per observation would
      # give 1062 — triple-billing a single machine's idle time, which is the
      # obvious wrong implementation and the reason this case is here.
      assert GpuWindow.billed_seconds(observations) == 420.0
    end

    test "two containers each bill their own tail" do
      assert GpuWindow.billed_seconds([{"c1", 10.0}, {"c2", 30.0}]) == 640.0
    end

    # ⬛ ANTI-VACUITY: the tail must actually be the dominant term for a
    # lightly-used container. If this ratio collapsed to ~1 the model would
    # have stopped accounting for idle time at all, which is the entire point.
    test "for a single short request the tail dominates the measured time" do
      billed = GpuWindow.billed_seconds([{"c1", 1.0}])

      assert billed / 1.0 > 100,
             "the idle tail should dwarf a one-second inference; got #{billed}s billed for 1s " <>
               "of observed work, which means idle time is no longer being counted"
    end
  end

  describe "an observation that cannot be attributed is counted, not dropped" do
    test "readings with no container id are reported" do
      observations = [{nil, 5.0}, {"", 5.0}, {"c1", 5.0}]

      assert GpuWindow.unattributable_count(observations) == 2
      assert GpuWindow.billed_seconds(observations) == 305.0
    end

    # ⛔ A ZERO HERE HAS TWO CAUSES AND THEY ARE OPPOSITE FACTS. An empty run
    # means no GPU ran; a run of unattributable readings means a GPU image
    # predating the id field DID run and we cannot say for how long. Reading
    # the billed figure without the count cannot tell those apart, and treating
    # the second as the first would report a busy GPU as free.
    test "zero billed seconds is distinguishable from zero attributable readings" do
      assert GpuWindow.billed_seconds([]) == 0
      assert GpuWindow.unattributable_count([]) == 0

      assert GpuWindow.billed_seconds([{nil, 9.0}, {nil, 9.0}]) == 0
      assert GpuWindow.unattributable_count([{nil, 9.0}, {nil, 9.0}]) == 2
    end
  end

  describe "the window agrees with the deployment it models" do
    # ⛔ THE FIGURE IS WRONG BY EXACTLY THE DIFFERENCE IF THESE DRIFT, and
    # nothing at runtime can detect it: the sidecar does not report its own
    # `scaledown_window`, so this constant is an assumption about a file in
    # another language. Asserting against the Python source is what turns a
    # silent cost skew into a failing test.
    test "the scaledown window matches the GPU class's configuration" do
      source = File.read!(Path.join([__DIR__, "..", "..", "..", "..", "vision", "modal_app.py"]))

      windows =
        ~r/scaledown_window=(\d+)/
        |> Regex.scan(source)
        |> Enum.map(fn [_, n] -> String.to_integer(n) end)

      assert windows != [],
             "no scaledown_window found in modal_app.py — the regex or the file moved, and " <>
               "this assertion is vacuous until it is fixed"

      # ⛔ THE FILE CONFIGURES TWO WINDOWS AND ONLY ONE IS THE GPU'S. A probe
      # found this: with `@scaledown_window_s` set to 240 the failure message
      # read "modal_app.py configures [300, 1200]", which exposed that an
      # `in windows` assertion would have ALSO passed for 1200 — the sidecar's
      # CPU window. So the loose form would hold while this module billed GPU
      # idle at the cheap container's window, a 4× error in the figure the
      # architecture decision turns on.
      #
      # ⚖️ The GPU's window is the one in the decorator that requests a GPU, so
      # the source is sliced at that decorator and only the first window after
      # it is read.
      [_, gpu_section] = String.split(source, "gpu=", parts: 2)

      [[_, gpu_window_str]] =
        Regex.scan(~r/scaledown_window=(\d+)/, gpu_section) |> Enum.take(1)

      gpu_window = String.to_integer(gpu_window_str)

      assert GpuWindow.scaledown_window_s() == gpu_window,
             "GpuWindow uses #{GpuWindow.scaledown_window_s()}s but the GPU class configures " <>
               "#{gpu_window}s (the file also has #{inspect(windows -- [gpu_window])} for " <>
               "non-GPU containers) — the billed-seconds figure is wrong by their difference " <>
               "and nothing at runtime can see it"
    end
  end
end
