defmodule Stacks.Books.HttpClientBehaviour do
  @moduledoc """
  Behaviour for the Books HTTP client — allows test mocking via Application env
  (`:isbn_http_client`). Covers ISBN-resolver JSON fetches (`get/1`) and the
  cover-image binary fetch (`get_binary/1`, #381a). Reusing one seam keeps every
  outbound Books request mockable through a single config key.
  """

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

  @doc """
  Fetches raw bytes (a cover image), rather than decoding JSON (#381a). Same
  closed error set as `get/1`. Seamed so `Books.download_cover/1` cannot dial a
  third party during tests — the assertion there was previously green only
  because a real request to `example.com` happened to return non-200.
  """
  @callback get_binary(url :: String.t()) :: {:ok, binary()} | {:error, error_reason()}
end
