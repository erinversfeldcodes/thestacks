defmodule Stacks.AI.TogetherClientBehaviour do
  @moduledoc "Behaviour for the Together AI LLM client — allows test mocking via Application env."

  @callback complete(prompt :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}
end
