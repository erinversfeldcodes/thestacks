defmodule Stacks.Discovery.MockBraveClient do
  @moduledoc """
  Mock Brave Search client for tests.

  Responses are stored in the process dictionary so each test process is
  isolated and tests can run with `async: true`.

  ## Usage

      MockBraveClient.put_response({:ok, [%{title: "Author Blog", url: "https://author.com", description: "..."}]})

  """

  @behaviour Stacks.Discovery.BraveClientBehaviour

  @impl true
  def search(_query, _opts \\ []) do
    case Process.get({__MODULE__, :response}) do
      nil -> {:ok, []}
      response -> response
    end
  end

  @doc "Register a response to return for the next search call."
  def put_response(response) do
    Process.put({__MODULE__, :response}, response)
  end

  @doc "Clear the registered response for the current process."
  def clear do
    Process.delete({__MODULE__, :response})
  end
end
