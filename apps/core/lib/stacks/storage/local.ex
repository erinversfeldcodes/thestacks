defmodule Stacks.Storage.Local do
  @moduledoc """
      Local filesystem storage backend for development.

      Stores files under `priv/static/uploads/` (configurable via `:upload_dir`).
      Presigned URLs return `file://` paths — only suitable for local development.

      GDPR export objects are the exception: `priv/static/uploads` is served by
      `Plug.Static`, and an export is a complete copy of one user's personal
      data, so `exports/` keys land under `:export_dir` (`priv/exports`) where
      the endpoint cannot reach them.
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
  @spec list(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(prefix) do
    base = base_for(prefix)

    keys =
      base
      |> Path.join(prefix)
      |> Path.join("**")
      |> Path.wildcard()
      |> Enum.reject(&File.dir?/1)
      |> Enum.map(&Path.relative_to(&1, base))

    {:ok, keys}
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

  defp full_path(key), do: Path.join(base_for(key), key)

  defp base_for("exports/" <> _), do: Application.get_env(:core, :export_dir, "priv/exports")
  defp base_for(_key), do: Application.get_env(:core, :upload_dir, "priv/static/uploads")
end
