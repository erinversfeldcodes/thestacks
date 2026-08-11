defmodule Stacks.Books.HttpClient do
  @moduledoc "Real HTTP client for ISBN resolver — uses Finch."

  @behaviour Stacks.Books.HttpClientBehaviour

  require Logger

  @impl true
  def get(url) do
    req = Finch.build(:get, url)

    case Finch.request(req, Stacks.Finch, receive_timeout: 15_000, request_timeout: 15_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        decode_body(body, url)

      {:ok, %Finch.Response{status: status}} ->
        Logger.warning("ISBNResolver: unexpected status #{status} for #{url}")
        {:error, :unexpected_status}

      {:error, error} ->
        map_error(error, url)
    end
  end

  @impl true
  def get_binary(url) do
    req = Finch.build(:get, url)

    case Finch.request(req, Stacks.Finch, receive_timeout: 10_000, request_timeout: 10_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Finch.Response{status: status}} ->
        Logger.warning("Books.get_binary: unexpected status #{status} for #{url}")
        {:error, :unexpected_status}

      {:error, error} ->
        map_error(error, url)
    end
  end

  @doc false
  @spec map_error(term(), String.t()) ::
          {:error, Stacks.Books.HttpClientBehaviour.error_reason()}
  def map_error(%Finch.TransportError{reason: :timeout} = error, url) do
    Logger.warning("ISBNResolver: request timed out for #{url}: #{inspect(error)}")
    {:error, :timeout}
  end

  def map_error(%Finch.Error{reason: reason} = error, url)
      when reason in [:timeout, :request_timeout] do
    Logger.warning("ISBNResolver: request timed out for #{url}: #{inspect(error)}")
    {:error, :timeout}
  end

  def map_error(%Finch.TransportError{} = error, url) do
    Logger.warning("ISBNResolver: transport error for #{url}: #{inspect(error)}")
    {:error, :transport_error}
  end

  def map_error(error, url) do
    Logger.warning("ISBNResolver: request failed for #{url}: #{inspect(error)}")
    {:error, :transport_error}
  end

  defp decode_body(body, url) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, %Jason.DecodeError{} = reason} ->
        Logger.warning("ISBNResolver: malformed JSON body for #{url}: #{inspect(reason)}")

        {:error, :malformed_response}
    end
  end
end
