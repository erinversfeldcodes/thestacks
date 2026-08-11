defmodule Stacks.Storage.Local do
  @moduledoc """
  Local filesystem storage backend for development.

  Stores files under `priv/static/uploads/` (configurable via `:upload_dir`).
  Presigned URLs return `file://` paths — only suitable for local development.
  """

  @behaviour Stacks.Storage.StorageBehaviour

  require Logger

  @impl true
  @spec put(String.t(), binary(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def put(key, data, _opts \\ []) do
    path = full_path(key)
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, data) do
      Logger.info("Storage.Local: wrote #{path}")
      {:ok, key}
    else
      {:error, reason} ->
        Logger.error("Storage.Local: write failed for #{key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  @spec presigned_url(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def presigned_url(key, _ttl_seconds \\ 900) do
    {:ok, "file://#{full_path(key)}"}
  end

  @impl true
  @spec presigned_put_url(String.t(), pos_integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def presigned_put_url(key, _ttl_seconds \\ 900, _opts \\ []) do
    {:ok, "file://#{full_path(key)}"}
  end

  @impl true
  @spec head(String.t()) :: {:ok, non_neg_integer()} | {:error, :not_found | term()}
  def head(key) do
    path = full_path(key)

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key) do
    path = full_path(key)

    case File.rm(path) do
      :ok ->
        Logger.info("Storage.Local: deleted #{path}")
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.error("Storage.Local: delete failed for #{key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp full_path(key) do
    base = Application.get_env(:core, :upload_dir, "priv/static/uploads")
    Path.join(base, key)
  end
end
