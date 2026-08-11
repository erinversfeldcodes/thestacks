defmodule Stacks.Books.MockHttpClient do
  @moduledoc """
  Mock HTTP client for ISBNResolver tests. Responses live in the process
  dictionary keyed by URL substring (isolated, `async: true`-safe); the
  most recently registered matching pattern wins.

      MockHttpClient.put_response("openlibrary.org/search.json", {:ok, %{"docs" => [...]}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{"items" => [...]}})

  An unmatched URL returns `{:error, :not_found}`.
  """

  @behaviour Stacks.Books.HttpClientBehaviour

  @capture_key {__MODULE__, :capture_pid}

  @impl true
  def get(url) do
    notify_capture(url)
    responses = lookup_responses()

    case Enum.find(responses, fn {pattern, _} -> String.contains?(url, pattern) end) do
      {_, response} -> response
      nil -> {:ok, %{}}
    end
  end

  @impl true
  def get_binary(url) do
    notify_capture(url)
    responses = lookup_responses()

    case Enum.find(responses, fn {pattern, _} -> String.contains?(url, pattern) end) do
      {_, response} ->
        response

      nil ->
        {:error, :transport_error}
    end
  end

  @doc "Register a response for URLs containing `pattern`. Later registrations take priority."
  def put_response(pattern, response) do
    responses = Process.get(__MODULE__, [])
    Process.put(__MODULE__, [{pattern, response} | responses])
  end

  @doc """
    Capture every requested URL by sending `{Stacks.Books.MockHttpClient,
  :request, url}` to the calling (test) process. Uses the same
    `$callers`-walking process-dictionary mechanism as `put_response/2`,
    so requests made from Tasks spawned by the code under test are
    captured too. Lets tests assert on the exact query the resolver
    built (e.g. that a corrupted keyword or `inauthor:null` never goes
    out on the wire).
  """
  def capture_requests do
    Process.put(@capture_key, self())
  end

  @doc "Clear all registered responses for the current process."
  def clear do
    Process.delete(__MODULE__)
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

  defp notify_capture(url) do
    case find_capture_pid([self() | Process.get(:"$callers", [])]) do
      nil -> :ok
      pid -> send(pid, {__MODULE__, :request, url})
    end
  end

  defp find_capture_pid([]), do: nil

  defp find_capture_pid([pid | rest]) do
    case safe_capture_get(pid) do
      nil -> find_capture_pid(rest)
      capture_pid -> capture_pid
    end
  end

  defp safe_capture_get(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> dict |> List.keyfind(@capture_key, 0, {nil, nil}) |> elem(1)
      nil -> nil
    end
  end
end
