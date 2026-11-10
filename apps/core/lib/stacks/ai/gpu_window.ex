defmodule Stacks.AI.GpuWindow do
  @moduledoc """
  Turns the GPU container readings on a vision response into billed seconds.

  ⛔ **The age on a response is a SAMPLE of a container's life, not its life.**
  It is observed only when an inference runs, so a container that wakes, serves
  one request and then idles out the rest of its scaledown window reports an age
  near zero and nothing afterwards — and the idle seconds are precisely the ones
  with no request attached to them. Summing observed ages therefore under-counts
  the billed time, in the direction that makes the GPU look cheap, which is the
  direction that would wrongly settle the architecture question this figure
  exists to answer.

  ⚖️ So the billed window for a container is the **maximum age seen for its id,
  plus the scaledown window Modal bills after the last request**. That second
  term is the whole point: it is the idle tail, it is never sampled by any
  request, and it is the larger share of the bill for a container that served
  one image.

  ⚠️ **This is a lower bound that becomes exact once a container is gone.**
  While a container is alive, a later request can extend it, so the figure for
  the current container can only grow. A reader comparing it to Modal's invoice
  should expect this to sit at or below the invoice, never above — and a figure
  that exceeds the invoice means the model is wrong, not that Modal is.
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
  Billed seconds implied by a set of `{container_id, age_s}` observations.

  Groups by container, takes each one's maximum observed age, and adds the
  scaledown tail once per container — not once per observation, which would
  multiply the tail by the request count.
  """
  def billed_seconds(observations) when is_list(observations) do
    observations
    |> Enum.reject(fn {id, age} -> is_nil(id) or id == "" or is_nil(age) end)
    |> Enum.group_by(fn {id, _age} -> id end, fn {_id, age} -> age end)
    |> Enum.map(fn {_id, ages} -> Enum.max(ages) + @scaledown_window_s end)
    |> Enum.sum()
  end

  @doc """
  How many of these observations could say nothing about billed time.

  ⬛ Reported rather than silently dropped. An observation with no container id
  is a response from a GPU image deployed before the id existed, and a run made
  up entirely of those yields `billed_seconds/1` of zero — which is
  indistinguishable from "the GPU never ran" unless this count is read beside
  it. A zero with a high unattributable count is a deployment gap; a zero with
  none is a real absence of GPU work.
  """
  def unattributable_count(observations) when is_list(observations) do
    Enum.count(observations, fn {id, age} -> is_nil(id) or id == "" or is_nil(age) end)
  end
end
