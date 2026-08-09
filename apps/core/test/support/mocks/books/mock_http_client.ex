defmodule Stacks.Books.MockHttpClient do
  @moduledoc """
  Mock HTTP client for ISBNResolver tests.

  Responses are stored in the process dictionary keyed by URL substring,
  so each test process is isolated and tests can run with `async: true`.

  ## Usage

      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{"ISBN:123" => ...}})
      MockHttpClient.put_response("openlibrary.org/search.json", {:ok, %{"docs" => [...]}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{"items" => [...]}})

  The **most recently** registered pattern whose substring matches the requested
  URL wins — registrations are prepended, so a later `put_response/2` overrides
  an earlier one for the same (or an overlapping) pattern. That is the useful
  semantic for a test overriding a response installed by its `setup` block, and
  it is what the code has always done; the moduledoc previously claimed
  first-registration-wins, which was never true (Issue #327).
  Unmatched URLs return `{:ok, %{}}`.
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

      # Unmatched cover fetches fail closed rather than dialling out (#381a), so
      # `download_cover/1` falls back to the source URL deterministically and no
      # test ever touches the network. Register a `{:ok, <<bytes>>}` response to
      # exercise the store-in-R2 path.
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
