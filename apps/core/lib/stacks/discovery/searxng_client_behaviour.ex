defmodule Stacks.Discovery.SearxngClientBehaviour do
  @moduledoc "Behaviour for SearXNG search client — allows test mocking via Application env."

  @callback search(query :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}
end
