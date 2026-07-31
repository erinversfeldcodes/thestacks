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
    case presign_error() do
      nil -> {:ok, "https://mock-storage.test/#{key}?signed=true"}
      reason -> {:error, reason}
    end
  end

  @impl true
  @spec presigned_put_url(String.t(), pos_integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def presigned_put_url(key, _ttl_seconds \\ 900, _opts \\ []) do
    {:ok, "https://mock-storage.test/#{key}?signed=true&method=put"}
  end

  @impl true
  @spec head(String.t()) :: {:ok, non_neg_integer()} | {:error, :not_found | term()}
  def head(key) do
    store = Process.get(__MODULE__, %{})

    case Map.fetch(store, key) do
      {:ok, data} -> {:ok, byte_size(data)}
      :error -> {:error, :not_found}
    end
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

  @doc """
  Make `presigned_url/2` fail with `reason` for the current process.

  Presigning is the one storage call that happens *before* anything else in
  `Stacks.Workers.IdentifyBookJob`, so it is the only way to exercise that
  worker's earliest exit — the branch that returns `{:error, reason}` without
  the pipeline ever running. Without this seam a test aiming at that branch
  quietly takes the happy path instead and passes for the wrong reason.

  Pass `nil` to restore success.
  """
  @spec put_presign_error(term()) :: :ok
  def put_presign_error(reason) do
    Process.put({__MODULE__, :presign_error}, reason)
    :ok
  end

  # Walks `$callers` for the same reason `Stacks.AI.MockClient` does: the worker
  # runs its body in a Task, so the registration made in the test process has to
  # be visible from a descendant.
  defp presign_error do
    case Process.get({__MODULE__, :presign_error}, :undefined) do
      :undefined -> find_presign_error_in_callers(Process.get(:"$callers", []))
      reason -> reason
    end
  end

  defp find_presign_error_in_callers([]), do: nil

  defp find_presign_error_in_callers([pid | rest]) do
    with {:dictionary, dict} <- Process.info(pid, :dictionary),
         {_key, reason} <- List.keyfind(dict, {__MODULE__, :presign_error}, 0) do
      reason
    else
      _ -> find_presign_error_in_callers(rest)
    end
  end

  @doc "Clear all mock storage for the current process."
  @spec clear() :: :ok
  def clear do
    Process.delete(__MODULE__)
    Process.delete({__MODULE__, :presign_error})
    :ok
  end
end
