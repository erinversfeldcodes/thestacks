defmodule Stacks.AI.ClientBehaviour do
  @moduledoc """
    Behaviour for AI vision client — allows test mocking via Application env.

    The error side is `Stacks.AI.VisionError.t/0`, a closed set, so callers can
    branch on whether a failure was a determination about the image or a fault.
    The callback's type stays `term` because test doubles legitimately return
    reasons outside the set to exercise a caller's unknown-error handling; the
    guarantee is on `Stacks.AI.Client`, not on every implementation.
  """

  @callback call_vision(String.t(), map()) :: {:ok, map()} | {:error, term()}
end
