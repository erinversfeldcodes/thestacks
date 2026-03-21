defmodule Stacks.Storage.StorageBehaviour do
  @moduledoc """
  Behaviour for object storage backends.

  Implementations: `Stacks.Storage.R2` (Cloudflare R2 via ExAws S3),
  `Stacks.Storage.Local` (filesystem for dev), `Stacks.Storage.Mock` (tests).

  Swap via `config :core, :storage, Stacks.Storage.R2`.
  """

  @doc "Upload binary data to the given storage key. Returns `{:ok, key}` or `{:error, reason}`."
  @callback put(key :: String.t(), data :: binary(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Generate a presigned GET URL with the given TTL (seconds). Returns `{:ok, url}` or `{:error, reason}`."
  @callback presigned_url(key :: String.t(), ttl_seconds :: pos_integer()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Delete an object by key. Returns `:ok` or `{:error, reason}`."
  @callback delete(key :: String.t()) :: :ok | {:error, term()}
end
