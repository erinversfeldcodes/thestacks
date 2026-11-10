defmodule Stacks.AI.GpuWindow do
  @moduledoc """
  Reads the GPU container facts a vision response reports.

  ⛔ **An earlier version of this module held an exact billed-seconds model —
  maximum observed container age per container, plus one scaledown tail each —
  and it was deleted rather than wired.** A reviewer showed why: that model
  differs from `cold_starts x window` by the sum of observed ages, which is
  exactly the term the inference cost line already bills per GPU-second. So
  wiring it would not have refined the idle figure; it would have added a
  double-counted term, and the container age it needed had no other possible
  consumer. The age is gone from the wire with it.

  ⚖️ What survives is the scaledown window — the single source of the 300 that
  `Stacks.Costs` prices idle from, and the anchor for the assertion that keeps
  it equal to `apps/vision/modal_app.py` — and the de-duplication that turns a
  dispatch list into a count of container lifetimes.
  """

  # The GPU class's `scaledown_window` in `apps/vision/modal_app.py`. ⚠️ The two
  # must agree or this figure is wrong by exactly their difference, and nothing
  # here can detect that — the sidecar does not report its own configuration.
  # A test asserts the value against the Python source so a change to one side
  # fails rather than silently skewing the cost.
  @scaledown_window_s 300

  @doc "The GPU scaledown window, in seconds, that the billed tail is taken from."
  def scaledown_window_s, do: @scaledown_window_s

  @doc """
  How many distinct GPU containers were cold among one response's dispatches.

  ⛔ **Counting cold flags is not the same as counting containers**, and the
  difference is the whole reason the dispatch list carries a container id. One
  `/analyze` request makes up to two independent Modal dispatches, so a count
  of `cold` booleans double-counts if both landed on the same container.

  ⚠️ Those two happen to agree under today's deployment: the GPU class sets no
  per-container concurrency, so a container serves one input at a time and its
  cold flag is true exactly once per lifetime. The grouping is what keeps this
  correct when that changes — and raising inputs per container is precisely the
  obvious next cost move, since it is how the idle tail gets amortised.

  ⚖️ Derived in core from observations core can re-derive, rather than trusted
  as a scalar from the sidecar. This figure reaches a public money page, and
  the only cost series in this system worth trusting is trustworthy because it
  can catch our own arithmetic being wrong.
  """
  def cold_container_count(dispatches) when is_list(dispatches) do
    dispatches
    |> Enum.filter(&cold?/1)
    |> Enum.map(&container_id/1)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> length()
  end

  defp cold?(%{"cold" => true}), do: true
  defp cold?(_), do: false

  defp container_id(%{"container_id" => id}) when is_binary(id), do: id
  defp container_id(_), do: nil
end
