defmodule Stacks.AI.MockClient do
  @moduledoc """
  Mock implementation of the vision client (`Stacks.AI.ClientBehaviour`) for tests.

  Responses are steered **per endpoint** through the process dictionary, so each
  test process is isolated and tests can run with `async: true`. An endpoint with
  no registered response falls back to the canned default below.

  ## Usage

      MockClient.put_response("analyze", {:ok, %{"classification" => "CLASSIFICATION_RESULT_NOT_BOOK"}})
      MockClient.put_response("extract_isbn", {:error, :service_unavailable})
      MockClient.put_response(:any, {:error, :circuit_open})
      MockClient.put_response("analyze", fn payload -> {:ok, build_from(payload)} end)

  A registered response is either a literal term (returned as-is) or a 1-arity
  function of the payload (called, its result returned).

  The endpoints are the logical names `Stacks.AI.Client.call_vision/2` dispatches
  on: `"is_book"`, `"extract_isbn"`, `"analyze"`, `"associate"`. Register under
  `:any` to steer every endpoint at once; an exact-endpoint registration wins
  over an `:any` one.

  **The most recent registration for an endpoint wins** (same semantic as
  `Stacks.Books.MockHttpClient`), so a test can override a response installed by
  its `setup` block. `clear/0` drops every registration for the current process.

  Registrations survive `Task.async`/`Task.async_stream`: lookup walks the
  `$callers` chain, so work the moderation pipeline farms out to tasks sees the
  responses the test process registered.
  """

  @behaviour Stacks.AI.ClientBehaviour

  @default_isbn "9780743273565"

  @impl true
  def call_vision(endpoint, payload) do
    case steered_response(endpoint) do
      {:steered, fun} when is_function(fun, 1) -> fun.(payload)
      {:steered, response} -> response
      :none -> default_response(endpoint, payload)
    end
  end

  @doc """
  Register `response` for `endpoint` in the current process.

  Later registrations take priority. `endpoint` is a logical endpoint string
  (`"is_book"`, `"extract_isbn"`, `"analyze"`, `"associate"`) or `:any` to
  match every endpoint that has no exact registration.
  """
  def put_response(endpoint, response) do
    Process.put(__MODULE__, [{endpoint, response} | Process.get(__MODULE__, [])])
    :ok
  end

  @doc "Clear all registered responses for the current process."
  def clear do
    Process.delete(__MODULE__)
    :ok
  end

  defp steered_response(endpoint) do
    responses = lookup_responses()

    case List.keyfind(responses, endpoint, 0) || List.keyfind(responses, :any, 0) do
      {_endpoint, response} -> {:steered, response}
      nil -> :none
    end
  end

  defp lookup_responses do
    case Process.get(__MODULE__, :undefined) do
      :undefined -> find_in_callers(Process.get(:"$callers", []))
      responses -> responses
    end
  end

  defp find_in_callers([]), do: []

  defp find_in_callers([pid | rest]) do
    case safe_dict_get(pid) do
      nil -> find_in_callers(rest)
      responses -> responses
    end
  end

  defp safe_dict_get(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, __MODULE__)
      nil -> nil
    end
  end

  defp default_response("is_book", _payload) do
    {:ok,
     %{
       "classification" => "CLASSIFICATION_RESULT_BOOK",
       "confidence" => 0.9,
       "model_used" => "mock"
     }}
  end

  defp default_response("extract_isbn", payload) do
    {:ok,
     %{
       "books" => [book_result(payload_isbn(payload))],
       "model_used" => "mock"
     }}
  end

  defp default_response("analyze", payload) do
    {:ok,
     %{
       "classification" => "CLASSIFICATION_RESULT_BOOK",
       "confidence" => 0.9,
       "books" => [book_result(payload_isbn(payload))],
       "model_used" => "mock"
     }}
  end

  defp default_response("associate", %{isbn: isbn, edition_id: edition_id}) do
    {:ok, %{"job_id" => "mock-job-#{isbn}-#{edition_id}"}}
  end

  defp default_response(_endpoint, _payload), do: {:ok, %{}}

  defp payload_isbn(payload) when is_map(payload) do
    Map.get(payload, :isbn) || Map.get(payload, "isbn") || @default_isbn
  end

  defp payload_isbn(_payload), do: @default_isbn

  defp book_result(isbn) do
    %{
      "title" => nil,
      "author" => nil,
      "potential_isbns" => [isbn],
      "raw_text" => nil,
      "confidence" => 0.9
    }
  end
end
