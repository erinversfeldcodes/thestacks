defmodule Stacks.Transparency.MockPrometheusClient do
  @moduledoc """
  Process-dictionary mock for the transparency Prometheus client (ADR-012).

  Responses are stored per-process so tests stay isolated. A call counter is
  maintained so the cache test can assert that a second `metrics/0` call within
  the TTL does NOT re-invoke the client.

  ## Usage

      MockPrometheusClient.put_response({:ok, 0.42})
      # ... exercise Stacks.Transparency ...
      assert MockPrometheusClient.call_count() == length(Transparency.whitelist_keys())
  """

  @behaviour Stacks.Transparency.PrometheusClient

  @impl true
  def query(promql) do
    increment_count()
    Process.put({__MODULE__, :last_query}, promql)

    case Process.get({__MODULE__, :response}) do
      nil -> {:ok, 0.0}
      response -> response
    end
  end

  @doc "Register the response returned for every subsequent query call."
  def put_response(response), do: Process.put({__MODULE__, :response}, response)

  @doc "How many times `query/1` has been called in this process."
  def call_count, do: Process.get({__MODULE__, :count}, 0)

  @doc "The exact PromQL string of the most recent `query/1` call (nil if none)."
  def last_query, do: Process.get({__MODULE__, :last_query})

  @doc "Reset the registered response and the call counter for this process."
  def reset do
    Process.delete({__MODULE__, :response})
    Process.delete({__MODULE__, :last_query})
    Process.put({__MODULE__, :count}, 0)
    :ok
  end

  defp increment_count, do: Process.put({__MODULE__, :count}, call_count() + 1)
end
