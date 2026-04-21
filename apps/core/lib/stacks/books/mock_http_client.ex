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
    responses = lookup_responses()

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

  # Walk the `$callers` chain so responses registered in the test process
  # are visible to Tasks spawned from it (e.g. ISBNResolver.race_resolve/1
  # spawns two parallel Task.async'd lookups). Elixir automatically puts
  # the caller hierarchy in `$callers` when a Task is started, so we can
  # check each ancestor's dictionary. Local dict wins; fall through to
  # ancestors only on miss.
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
end
