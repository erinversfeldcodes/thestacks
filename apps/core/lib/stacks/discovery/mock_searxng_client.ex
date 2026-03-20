defmodule Stacks.Discovery.MockSearxngClient do
  @moduledoc """
  Mock SearXNG client for tests.

  Responses are stored in the process dictionary so each test process is
  isolated and tests can run with `async: true`.

  ## Usage

      MockSearxngClient.put_response({:ok, [%{title: "Book Event", url: "https://example.com", description: "..."}]})

  """

  @behaviour Stacks.Discovery.SearxngClientBehaviour

  @impl true
  def search(_query, _opts \\ []) do
    case Process.get({__MODULE__, :response}) do
      nil -> {:ok, []}
      response -> response
    end
  end

  @doc "Register a response to return for the next search call."
  @spec put_response({:ok, [map()]} | {:error, term()}) :: term()
  def put_response(response) do
    Process.put({__MODULE__, :response}, response)
  end

  @doc "Clear the registered response for the current process."
  @spec clear() :: term()
  def clear do
    Process.delete({__MODULE__, :response})
  end
end
