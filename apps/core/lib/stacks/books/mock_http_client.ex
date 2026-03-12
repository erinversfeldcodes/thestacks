defmodule Stacks.Books.MockHttpClient do
  @moduledoc """
  Mock HTTP client for ISBNResolver tests.

  Responses are stored in the process dictionary keyed by URL substring,
  so each test process is isolated and tests can run with `async: true`.

  ## Usage

      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{"ISBN:123" => ...}})
      MockHttpClient.put_response("openlibrary.org/search.json", {:ok, %{"docs" => [...]}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{"items" => [...]}})

  The first registered pattern whose substring matches the requested URL wins.
  Unmatched URLs return `{:ok, %{}}`.
  """

  @behaviour Stacks.Books.HttpClientBehaviour

  @impl true
  def get(url) do
    responses = Process.get(__MODULE__, [])

    case Enum.find(responses, fn {pattern, _} -> String.contains?(url, pattern) end) do
      {_, response} -> response
      nil -> {:ok, %{}}
    end
  end

  @doc "Register a response for URLs containing `pattern`. Later registrations take priority."
  def put_response(pattern, response) do
    responses = Process.get(__MODULE__, [])
    Process.put(__MODULE__, [{pattern, response} | responses])
  end

  @doc "Clear all registered responses for the current process."
  def clear do
    Process.delete(__MODULE__)
  end
end
