defmodule Stacks.Storage.R2 do
  @moduledoc """
    Cloudflare R2 object storage via the ExAws S3 API (config under
    `Stacks.Storage.R2` + `:ex_aws` in runtime.exs). Protected by
    `:r2_fuse`: when blown, `put/3` and `delete/1` fast-fail
    `{:error,:circuit_open}` instead of blocking on a slow round-trip.
    `presigned_url/2` is NOT fuse-gated — it's a local SigV4 signing
    operation with no upstream call.
  """

  @behaviour Stacks.Storage.StorageBehaviour

  require Logger

  @fuse_name :r2_fuse

  @impl true
  @spec put(String.t(), binary(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def put(key, data, opts \\ []) do
    case :fuse.ask(@fuse_name, :sync) do
      :blown ->
        {:error, :circuit_open}

      _ ->
        do_put(key, data, opts)
    end
  end

  defp do_put(key, data, opts) do
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")

    bucket()
    |> ExAws.S3.put_object(key, data, content_type: content_type)
    |> ExAws.request()
    |> case do
      {:ok, _} ->
        Logger.info("Storage.R2: uploaded #{key}")
        {:ok, key}

      {:error, reason} ->
        Logger.error("Storage.R2: upload failed for #{key}: #{inspect(reason)}")
        Stacks.CircuitBreakers.melt(@fuse_name)
        {:error, reason}
    end
  end

  @impl true
  @spec presigned_url(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def presigned_url(key, ttl_seconds \\ 900) do
    config = ExAws.Config.new(:s3)

    {:ok, url} =
      ExAws.S3.presigned_url(config, :get, bucket(), key, expires_in: ttl_seconds)

    {:ok, url}
  rescue
    e ->
      Logger.error("Storage.R2: presigned URL failed for #{key}: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  @spec presigned_put_url(String.t(), pos_integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def presigned_put_url(key, ttl_seconds \\ 900, _opts \\ []) do
    config = ExAws.Config.new(:s3)

    case ExAws.S3.presigned_url(config, :put, bucket(), key, expires_in: ttl_seconds) do
      {:ok, url} -> {:ok, url}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      Logger.error("Storage.R2: presigned PUT URL failed for #{key}: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  @spec head(String.t()) :: {:ok, non_neg_integer()} | {:error, :not_found | term()}
  def head(key) do
    case :fuse.ask(@fuse_name, :sync) do
      :blown ->
        {:error, :circuit_open}

      _ ->
        do_head(key)
    end
  end

  defp do_head(key) do
    bucket()
    |> ExAws.S3.head_object(key)
    |> ExAws.request()
    |> case do
      {:ok, %{headers: headers}} ->
        size =
          headers
          |> Enum.find_value(fn
            {"Content-Length", v} -> v
            {"content-length", v} -> v
            _ -> nil
          end)
          |> case do
            nil -> 0
            v when is_binary(v) -> String.to_integer(v)
            v when is_integer(v) -> v
          end

        {:ok, size}

      {:error, {:http_error, 404, _}} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Storage.R2: head failed for #{key}: #{inspect(reason)}")
        Stacks.CircuitBreakers.melt(@fuse_name)
        {:error, reason}
    end
  end

  @impl true
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key) do
    case :fuse.ask(@fuse_name, :sync) do
      :blown ->
        {:error, :circuit_open}

      _ ->
        do_delete(key)
    end
  end

  defp do_delete(key) do
    bucket()
    |> ExAws.S3.delete_object(key)
    |> ExAws.request()
    |> case do
      {:ok, _} ->
        Logger.info("Storage.R2: deleted #{key}")
        :ok

      {:error, reason} ->
        Logger.error("Storage.R2: delete failed for #{key}: #{inspect(reason)}")
        Stacks.CircuitBreakers.melt(@fuse_name)
        {:error, reason}
    end
  end

  defp bucket do
    Application.get_env(:core, :r2_bucket, "stacks-images")
  end
end
