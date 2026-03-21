defmodule Stacks.Storage.Mock do
  @moduledoc """
  In-memory mock storage backend for tests.

  Stores data in the process dictionary so each test process is isolated
  and tests can run with `async: true`.

  ## Usage

      # Verify a file was stored:
      assert Stacks.Storage.Mock.get("uploads/some-id") != nil

      # Pre-seed data:
      Stacks.Storage.Mock.seed("covers/isbn-cover.jpg", <<image_bytes>>)
  """

  @behaviour Stacks.Storage.StorageBehaviour

  @impl true
  @spec put(String.t(), binary(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def put(key, data, _opts \\ []) do
    store = Process.get(__MODULE__, %{})
    Process.put(__MODULE__, Map.put(store, key, data))
    {:ok, key}
  end

  @impl true
  @spec presigned_url(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def presigned_url(key, _ttl_seconds \\ 900) do
    {:ok, "https://mock-storage.test/#{key}?signed=true"}
  end

  @impl true
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key) do
    store = Process.get(__MODULE__, %{})
    Process.put(__MODULE__, Map.delete(store, key))
    :ok
  end

  # ── Test helpers ──────────────────────────────────────────────────────────

  @doc "Retrieve stored data for a key. Returns `nil` if not present."
  @spec get(String.t()) :: binary() | nil
  def get(key) do
    store = Process.get(__MODULE__, %{})
    Map.get(store, key)
  end

  @doc "Seed mock storage with data for a key."
  @spec seed(String.t(), binary()) :: :ok
  def seed(key, data) do
    store = Process.get(__MODULE__, %{})
    Process.put(__MODULE__, Map.put(store, key, data))
    :ok
  end

  @doc "Clear all mock storage for the current process."
  @spec clear() :: :ok
  def clear do
    Process.delete(__MODULE__)
    :ok
  end
end
