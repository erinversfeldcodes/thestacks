defmodule Stacks.AI.MockClient do
  @moduledoc """
    Mock vision client (`Stacks.AI.ClientBehaviour`). Responses are steered
    per endpoint through the process dictionary (isolated, `async: true`-safe);
    unregistered endpoints fall back to the canned default.

        MockClient.put_response("analyze", {:error,:service_unavailable})
        MockClient.put_response(:any, {:error,:circuit_open})

    `:any` steers every endpoint; a specific endpoint registration wins over
    it. Response shapes come from `Stacks.Testing.VisionFixtures` — do not
    hand-write them.
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
      (`"is_book"`, `"analyze"`) or `:any` to match every endpoint that has no
      exact registration.

      ⚠️ Keep this list in step with `Stacks.AI.Client.endpoint_path/1`. It used
      to include `"extract_isbn"` and `"associate"`, and this mock kept
      answering both for a while after the real client stopped accepting them —
      a seam that outlives the thing it stands for will hand a test a cheerful
      success for an operation that cannot happen in production.
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

  # ⚠️ "is_book" answers with the SAME shape as "analyze", and must.
  #
  # It used to return a classification-only body — `{classification, confidence,
  # model_used}`, the response of the `/classify` endpoint. That endpoint was
  # deleted on 2026-10-15 and `endpoint_path/1` now resolves BOTH operation
  # names to `/analyze`, so in production a caller asking "is_book" receives an
  # `AnalyzeResponse` with a `books` key. A mock that kept answering in the old
  # shape would disagree with the real client about what the same call returns —
  # which is the failure this module's own moduledoc warns about, and it would
  # hand a test a confident green for a response production cannot produce.
  defp default_response("is_book", payload), do: default_response("analyze", payload)

  defp default_response("analyze", payload) do
    {:ok,
     %{
       "classification" => "CLASSIFICATION_RESULT_BOOK",
       "confidence" => 0.9,
       "books" => [book_result(payload_isbn(payload))],
       "model_used" => "mock"
     }}
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
