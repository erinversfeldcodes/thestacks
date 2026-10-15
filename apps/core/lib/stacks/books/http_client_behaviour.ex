defmodule Stacks.Books.HttpClientBehaviour do
  @moduledoc """
      Behaviour for the Books HTTP client — allows test mocking via Application env
      (`:isbn_http_client`). Covers the ISBN-resolver JSON fetches (`get/1`).
      One seam keeps every outbound Books request mockable through a single
      config key.

      ⚠️ A second callback, `get_binary/1`, lived here until 2026-10-15 for
      fetching a cover image's bytes. Its only caller was the cover-verification
      loop, which nothing ever triggered, and it had no behavioural test in any
      revision — so four implementations of it existed and none was exercised.
      Re-adding it is a dozen lines of Finch if a cover download is ever wanted
      again; keeping it was four copies of untested dead code.
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
end
