defmodule Stacks.AI.GpuWindowTest do
  use ExUnit.Case, async: true

  alias Stacks.AI.GpuWindow

  describe "a dispatch list becomes a count of container lifetimes" do
    test "one cold dispatch is one container" do
      assert GpuWindow.cold_container_count([%{"cold" => true, "container_id" => "a"}]) == 1
    end

    test "a warm dispatch is not a container lifetime" do
      assert GpuWindow.cold_container_count([%{"cold" => false, "container_id" => "a"}]) == 0
    end

    test "no dispatches is no containers" do
      assert GpuWindow.cold_container_count([]) == 0
    end

    # ⛔ THE CASE THE CONTAINER ID EXISTS FOR. Two cold dispatches that landed
    # on the SAME container are one lifetime, not two. Counting `cold` flags
    # would say two and bill 600 idle seconds for a machine that ran once.
    test "two cold dispatches on one container are one lifetime" do
      dispatches = [
        %{"cold" => true, "container_id" => "same"},
        %{"cold" => true, "container_id" => "same"}
      ]

      assert GpuWindow.cold_container_count(dispatches) == 1
    end

    # ⬛ ANTI-VACUITY for the case above: distinct ids must still count
    # separately, or the de-duplication has collapsed everything to one.
    test "two cold dispatches on different containers are two lifetimes" do
      dispatches = [
        %{"cold" => true, "container_id" => "one"},
        %{"cold" => true, "container_id" => "two"}
      ]

      assert GpuWindow.cold_container_count(dispatches) == 2
    end

    # ⛔ THE DEFECT THAT FORCED THIS SHAPE: the cold dispatch is the SECOND
    # one. The previous code read a single `gpu_cold` off the response, which
    # described only the classify dispatch — so this request recorded nothing
    # and its container was billed to nobody.
    test "a cold EXTRACT after a warm classify is counted" do
      dispatches = [
        %{"cold" => false, "container_id" => "warm-classify"},
        %{"cold" => true, "container_id" => "cold-extract"}
      ]

      assert GpuWindow.cold_container_count(dispatches) == 1,
             "a container woken by the extract dispatch was not counted — this is the " <>
               "under-count that made idle GPU cost look half what it is"
    end

    # ⚠️ A dispatch with no id cannot be attributed to a container, and is not
    # guessed at. A GPU image predating the field sends none, and inventing a
    # lifetime for it would over-count — the opposite error, equally wrong.
    test "a cold dispatch with no usable id is not counted" do
      assert GpuWindow.cold_container_count([%{"cold" => true}]) == 0
      assert GpuWindow.cold_container_count([%{"cold" => true, "container_id" => ""}]) == 0
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
