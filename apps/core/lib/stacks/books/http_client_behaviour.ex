defmodule Stacks.Books.HttpClientBehaviour do
  @moduledoc "Behaviour for ISBN resolver HTTP client — allows test mocking via Application env."

  @typedoc """
  Closed set of error reasons returned by `get/1`. Adding a new failure
  mode requires adding the atom here and updating every caller's
  exhaustive pattern match — dialyzer enforces this end-to-end.
  """
  @type error_reason ::
          :unexpected_status
          | :malformed_response
          | :transport_error
          | :timeout

  @callback get(url :: String.t()) :: {:ok, map()} | {:error, error_reason()}
end
