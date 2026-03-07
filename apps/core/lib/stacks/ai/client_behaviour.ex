defmodule Stacks.AI.ClientBehaviour do
  @moduledoc "Behaviour for AI vision client — allows test mocking via Application env."

  @callback call_vision(String.t(), map()) :: {:ok, map()} | {:error, term()}
end
