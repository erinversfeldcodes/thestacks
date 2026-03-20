defmodule Stacks.Discovery.BraveClientBehaviour do
  @moduledoc "Behaviour for Brave Search API client — allows test mocking via Application env."

  @callback search(query :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}
end
