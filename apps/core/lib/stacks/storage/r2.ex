defmodule Stacks.Storage.R2 do
  @moduledoc """
  Cloudflare R2 object storage backend via ExAws S3-compatible API.

  Configuration (runtime.exs):

      config :core, Stacks.Storage.R2,
        bucket: "thestacks-uploads",
        public_url: "https://uploads.thestacks.app"

      config :ex_aws, :s3,
        scheme: "https://",
        host: "<account_id>.r2.cloudflarestorage.com",
        region: "auto"

      config :ex_aws,
        access_key_id: ...,
        secret_access_key: ...

  Protected by `:r2_fuse` — managed by `Stacks.CircuitBreakers`. When
  the fuse is blown (R2 is unreachable, rate-limiting us, or returning
  5xx), `put/3` and `delete/1` fast-fail with `{:error, :circuit_open}`
  instead of blocking the caller on a slow HTTPS round-trip. `presigned_url/2`
  is not fuse-gated because it's a local SigV4 signing op — no upstream call.
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
