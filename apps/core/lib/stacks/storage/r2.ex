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

  import SweetXml, only: [sigil_x: 2]

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
  @spec list(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(prefix) do
    case :fuse.ask(@fuse_name, :sync) do
      :blown ->
        {:error, :circuit_open}

      _ ->
        do_list(prefix)
    end
  end

  # ListObjectsV2 is signed and issued by hand rather than through
  # `ExAws.request/1`: ExAws signs the operation as the GET it declares but the
  # request reaches R2 as a POST, and every list comes back
  # `SignatureDoesNotMatch`. Every other verb we use (PUT/GET/HEAD/DELETE) goes
  # through ExAws unharmed, so the workaround is confined to this one call —
  # ExAws still does the SigV4 signing, Req just sends the method it signed.
  defp do_list(prefix) do
    config = ExAws.Config.new(:s3)
    collect_pages(config, prefix, nil, [])
  rescue
    e ->
      Logger.error("Storage.R2: list failed for #{prefix}: #{inspect(e)}")
      Stacks.CircuitBreakers.melt(@fuse_name)
      {:error, e}
  end

  # R2 rejects an unsigned payload hash, so the empty-body digest is passed in
  # as a header — it has to be signed, not merely sent.
  @empty_body_sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  defp collect_pages(config, prefix, continuation_token, acc) do
    url = list_url(config, prefix, continuation_token)
    signable = [{"x-amz-content-sha256", @empty_body_sha256}]

    with {:ok, headers} <- ExAws.Auth.headers(:get, url, :s3, config, signable, ""),
         {:ok, body} <- get_page(url, headers) do
      keys = acc ++ SweetXml.xpath(body, ~x"//Contents/Key/text()"ls)

      case SweetXml.xpath(body, ~x"//NextContinuationToken/text()"s) do
        "" -> {:ok, keys}
        next -> collect_pages(config, prefix, next, keys)
      end
    else
      {:error, reason} ->
        Logger.error("Storage.R2: list failed for #{prefix}: #{inspect(reason)}")
        Stacks.CircuitBreakers.melt(@fuse_name)
        {:error, reason}
    end
  end

  defp get_page(url, headers) do
    case Req.get(url, headers: headers, decode_body: false, retry: false) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_url(config, prefix, continuation_token) do
    query =
      [{"list-type", "2"}, {"prefix", prefix}]
      |> then(fn params ->
        if continuation_token,
          do: params ++ [{"continuation-token", continuation_token}],
          else: params
      end)
      |> Enum.sort()
      |> URI.encode_query()

    "#{config.scheme}#{config.host}/#{bucket()}?#{query}"
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
