defmodule Stacks.VisionQueueCapTest do
  @moduledoc """
  The vision queue's concurrency and Modal's container cap are one decision.

  ⛔ They live in two languages in two directories, and nothing connected them
  but prose. A comment stating "concurrency 20 against max_containers=10" is
  correct exactly until someone changes either number, and then it is a comment
  that lies — which this project has learned outlives the code it describes.
  """
  use ExUnit.Case, async: true

  @modal_app Path.join([__DIR__, "..", "..", "..", "vision", "modal_app.py"])

  defp configured_vision_concurrency do
    :core
    |> Application.get_env(Oban, [])
    |> Keyword.get(:queues, [])
    |> Keyword.get(:vision)
  end

  defp modal_max_containers do
    source = File.read!(@modal_app)

    # The cap on the GPU class, which is the one the queue feeds. Sliced at the
    # decorator that requests a GPU so a cap added to a CPU class later cannot
    # be read as this one — the same trap that made the scaledown-window
    # assertion pass for the sidecar's window.
    [_, gpu_section] = String.split(source, "gpu=", parts: 2)

    [[_, cap]] = Regex.scan(~r/max_containers=(\d+)/, gpu_section) |> Enum.take(1)

    String.to_integer(cap)
  end

  test "the GPU container cap is readable from the deployment source" do
    cap = modal_max_containers()

    # ⬛ ANTI-VACUITY: every assertion below is about this number, so a regex
    # that silently stopped matching would make all of them vacuous rather
    # than failing.
    assert is_integer(cap) and cap > 0,
           "could not read max_containers from #{@modal_app} — the regex or the file moved, " <>
             "and every assertion in this module is vacuous until that is fixed"
  end

  test "the vision queue is oversubscribed against the container cap, deliberately" do
    concurrency = configured_vision_concurrency()
    cap = modal_max_containers()

    assert concurrency,
           "no :vision queue is configured, so the relationship this module exists to pin " <>
             "has no left-hand side"

    # ⚖️ Oversubscription is the intended state, and it is the CHEAPER one: a
    # container bills its whole scaledown window after its last request, so
    # keeping requests arriving back-to-back spreads one idle tail across many
    # identifications. Lowering concurrency to the cap would RAISE the
    # per-identification cost.
    assert concurrency > cap,
           "the vision queue (#{concurrency}) is no longer oversubscribed against the GPU cap " <>
             "(#{cap}). If that is deliberate, the cost reasoning in config.exs and " <>
             "docs/capacity-model.md both describe the old arrangement and are now wrong"

    # ⚠️ Bounded above as well. Unbounded oversubscription queues requests at
    # Modal until they exceed its request timeout, which surfaces as vision
    # failures rather than as a queue problem — a long way from the cause.
    assert concurrency <= cap * 3,
           "the vision queue (#{concurrency}) is more than three times the GPU cap (#{cap}); " <>
             "the overflow waits at Modal and will start timing out rather than queueing"
  end
end
