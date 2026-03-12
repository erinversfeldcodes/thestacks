defmodule Stacks.Books.HttpClientBehaviour do
  @moduledoc "Behaviour for ISBN resolver HTTP client — allows test mocking via Application env."

  @callback get(url :: String.t()) :: {:ok, map()} | {:error, term()}
end
