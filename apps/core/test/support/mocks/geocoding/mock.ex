defmodule Stacks.Geocoding.Mock do
  @moduledoc """
    Mock geocoder for tests.

    Responses are keyed by a substring of the query and held in the process dictionary, so
    each test process is isolated and tests can stay `async: true` — the same idiom as
    `Stacks.Books.MockHttpClient`.

    ## Default is failure, on purpose

    An unmatched query returns `{:error,:not_found}` rather than a plausible point. A
    mock that invented coordinates would make every test look like geocoding succeeded,
    and the unpositioned-space path — which is a real state the owner must be able to see —
    would never be exercised. A test that wants a position says so.
  """

  @behaviour Stacks.Geocoding

  @impl true
  def geocode(query) do
    Process.put({__MODULE__, :queries}, queries() ++ [query])

    Process.get({__MODULE__, :responses}, [])
    |> Enum.find(fn {pattern, _} -> String.contains?(query, pattern) end)
    |> case do
      {_, response} -> response
      nil -> {:error, :not_found}
    end
  end

  @doc "Register a response for queries containing `pattern`. Later registrations win."
  def put_response(pattern, response) do
    responses = Process.get({__MODULE__, :responses}, [])
    Process.put({__MODULE__, :responses}, [{pattern, response} | responses])
  end

  @doc "Register a successful point for queries containing `pattern`."
  def put_point(pattern, latitude, longitude) do
    put_response(pattern, {:ok, %{latitude: latitude, longitude: longitude}})
  end

  @doc "Every query this process asked for, in order — lets a test assert none was made."
  def queries, do: Process.get({__MODULE__, :queries}, [])

  @doc "Clear registered responses and recorded queries."
  def clear do
    Process.delete({__MODULE__, :responses})
    Process.delete({__MODULE__, :queries})
  end
end
