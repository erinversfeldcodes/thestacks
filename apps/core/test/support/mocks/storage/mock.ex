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
    case steered_error(:put) do
      nil ->
        store = Process.get(__MODULE__, %{})
        Process.put(__MODULE__, Map.put(store, key, data))
        {:ok, key}

      reason ->
        {:error, reason}
    end
  end

  @impl true
  @spec presigned_url(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def presigned_url(key, ttl_seconds \\ 900) do
    case steered_error(:presign) do
      nil -> {:ok, "https://mock-storage.test/#{key}?signed=true&expires_in=#{ttl_seconds}"}
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
  @spec list(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(prefix) do
    case steered_error(:list) do
      nil ->
        keys =
          __MODULE__
          |> Process.get(%{})
          |> Map.keys()
          |> Enum.filter(&String.starts_with?(&1, prefix))

        {:ok, keys}

      reason ->
        {:error, reason}
    end
  end

  @impl true
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key) do
    case steered_error(:delete) do
      nil ->
        store = Process.get(__MODULE__, %{})
        Process.put(__MODULE__, Map.delete(store, key))
        :ok

      reason ->
        {:error, reason}
    end
  end

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
  def put_presign_error(reason), do: steer_error(:presign, reason)

  @doc """
      Make the named operation (`:put`, `:list`, `:delete`, `:presign`) fail
      with `reason` for the current process.

      A storage backend that never fails is the reason a worker can drop its
      output on the floor and still look green, so every leg the GDPR export
      delivery leans on — store, sign, sweep — needs a way to say no. Pass
      `nil` to restore success.
  """
  @spec steer_error(:put | :list | :delete | :presign, term()) :: :ok
  def steer_error(operation, reason) do
    Process.put({__MODULE__, operation}, reason)
    :ok
  end

  @steerable [:put, :list, :delete, :presign]

  defp steered_error(operation) do
    case Process.get({__MODULE__, operation}, :undefined) do
      :undefined -> find_error_in_callers(operation, Process.get(:"$callers", []))
      reason -> reason
    end
  end

  defp find_error_in_callers(_operation, []), do: nil

  defp find_error_in_callers(operation, [pid | rest]) do
    with {:dictionary, dict} <- Process.info(pid, :dictionary),
         {_key, reason} <- List.keyfind(dict, {__MODULE__, operation}, 0) do
      reason
    else
      _ -> find_error_in_callers(operation, rest)
    end
  end

  @doc "Clear all mock storage for the current process."
  @spec clear() :: :ok
  def clear do
    Process.delete(__MODULE__)
    Enum.each(@steerable, &Process.delete({__MODULE__, &1}))
    :ok
  end
end
