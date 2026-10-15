defmodule Stacks.Storage do
  @moduledoc """
      Storage context — upload, retrieve, and delete images from the configured
      object storage backend (R2 in production, Local in dev, Mock in test).

      Storage keys follow these conventions:
      - User uploads: `uploads/{image_id}`
      - Book covers:  `covers/{isbn}-cover.jpg` — ⚠️ NO LONGER WRITTEN. `store_cover/3`
        was the only writer of this prefix and its only caller was the
        cover-verification loop, which nothing ever triggered, so no object with
        this key was ever created. Both were deleted 2026-10-15. The prefix is
        documented here so a rebuild reuses it rather than inventing a second
        layout, not because anything is stored under it.
      - GDPR exports: `exports/{user_id}/{unix_expiry}-{token}.json`
        (owned by `Stacks.GDPR.ExportDelivery`, which builds the key)

      Presigned URLs have a 15 minute (900 second) TTL by default.
  """

  require Logger

  @default_ttl 900

  @doc """
      Upload an image to object storage.

      Returns `{:ok, storage_key}` on success.
  """
  @spec upload_image(String.t(), binary(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def upload_image(image_id, data, opts \\ []) do
    key = "uploads/#{image_id}"
    content_type = Keyword.get(opts, :content_type, "image/jpeg")
    backend().put(key, data, content_type: content_type)
  end

  @doc """
      Generate a presigned GET URL for an image.

      Returns `{:ok, url}` with a time-limited URL.
  """
  @spec get_image_url(String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def get_image_url(storage_key, ttl_seconds \\ @default_ttl) do
    signed_download_url(storage_key, ttl_seconds)
  end

  @doc """
      Generate a signed GET URL for any object.

      The signature is what stands between the object and the world — nothing
      in the bucket is reachable without one — so the TTL passed here is the
      access window, not a hint.
  """
  @spec signed_download_url(String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def signed_download_url(storage_key, ttl_seconds \\ @default_ttl) do
    backend().presigned_url(storage_key, ttl_seconds)
  end

  @doc """
      Generate a presigned PUT URL the client can upload an image to
      directly. Used by the init/commit upload flow to keep the Phoenix
      handler pool out of the R2 upload path.

      `content_type` hint is propagated to the PUT signature so R2 records
      the object with the correct MIME type.
  """
  @spec presigned_put_url(String.t(), pos_integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def presigned_put_url(storage_key, ttl_seconds \\ @default_ttl, opts \\ []) do
    backend().presigned_put_url(storage_key, ttl_seconds, opts)
  end

  @doc """
      Check whether an object exists at the given storage key. Used by the
      upload commit step to confirm the client's direct PUT to R2 succeeded
      before enqueueing identification work.
  """
  @spec head_image(String.t()) :: {:ok, non_neg_integer()} | {:error, :not_found | term()}
  def head_image(storage_key) do
    backend().head(storage_key)
  end

  @doc """
      Store a serialised GDPR data export at a caller-supplied key.

      The key encodes the object's own deadline, so
      `Stacks.GDPR.ExportDelivery` — not this context — decides it.
  """
  @spec put_export(String.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def put_export(storage_key, json) do
    backend().put(storage_key, json, content_type: "application/json")
  end

  @doc """
      List the keys of every object under a prefix. Used by the retention
      sweeps; the trailing slash is the caller's to supply.
  """
  @spec list_objects(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_objects(prefix) do
    backend().list(prefix)
  end

  @doc """
      Delete any object from storage by key.

      Returns `:ok` on success.
  """
  @spec delete_object(String.t()) :: :ok | {:error, term()}
  def delete_object(storage_key) do
    backend().delete(storage_key)
  end

  @doc """
      Delete an image from object storage.

      Returns `:ok` on success.
  """
  @spec delete_image(String.t()) :: :ok | {:error, term()}
  def delete_image(storage_key) do
    delete_object(storage_key)
  end

  defp backend do
    Application.get_env(:core, :storage, Stacks.Storage.Local)
  end
end
