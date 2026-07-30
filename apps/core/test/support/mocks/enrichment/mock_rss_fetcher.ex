defmodule Stacks.Enrichment.MockRssFetcher do
  @moduledoc """
  Mock RSS fetcher for tests.

  Responses are stored in the process dictionary so each test process is
  isolated and tests can run with `async: true`.

  ## Usage

      MockRssFetcher.put_response({:ok, %{entries: [%{title: "New Post", ...}]}})

  """

  @behaviour Stacks.Enrichment.RssFetcherBehaviour

  @spec fetch_and_parse(String.t()) :: {:ok, map()} | {:error, term()}
  @impl true
  def fetch_and_parse(_url) do
    case Process.get({__MODULE__, :response}) do
      nil -> {:ok, %{entries: []}}
      response -> response
    end
  end

  @doc "Register a response to return for the next fetch_and_parse call."
  @spec put_response({:ok, map()} | {:error, term()}) :: term()
  def put_response(response) do
    Process.put({__MODULE__, :response}, response)
  end

  @doc "Clear the registered response for the current process."
  @spec clear() :: term()
  def clear do
    Process.delete({__MODULE__, :response})
  end
end
