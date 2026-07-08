defmodule Stacks.Storage do
  @moduledoc """
  Storage context — upload, retrieve, and delete images from the configured
  object storage backend (R2 in production, Local in dev, Mock in test).

  Storage keys follow these conventions:
  - User uploads: `uploads/{image_id}`
  - Book covers:  `covers/{isbn}-cover.jpg`

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
  Delete an image from object storage.

  Returns `:ok` on success.
  """
  @spec delete_image(String.t()) :: :ok | {:error, term()}
  def delete_image(storage_key) do
    backend().delete(storage_key)
  end

  @doc """
  Store a book cover image.

  Returns `{:ok, storage_key}` on success.
  """
  @spec store_cover(String.t(), binary(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def store_cover(isbn, data, opts \\ []) do
    key = "covers/#{isbn}-cover.jpg"
    content_type = Keyword.get(opts, :content_type, "image/jpeg")
    backend().put(key, data, content_type: content_type)
  end

  defp backend do
    Application.get_env(:core, :storage, Stacks.Storage.Local)
  end
end
