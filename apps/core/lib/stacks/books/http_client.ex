defmodule Stacks.Books.HttpClient do
  @moduledoc "Real HTTP client for ISBN resolver — uses Finch."

  @behaviour Stacks.Books.HttpClientBehaviour

  require Logger

  @impl true
  def get(url) do
    req = Finch.build(:get, url)

    case Finch.request(req, Stacks.Finch) do
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

    # Bound BOTH the per-receive idle window AND the whole request (#381d): a
    # cover host that accepts the connection then dribbles bytes forever would
    # otherwise hang past `receive_timeout`. Covers are small, so 10s each is
    # generous.
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

  # Finch >= 0.23 wraps every failure in one of its own exception structs
  # (`t:Finch.error/0`): `%Finch.TransportError{reason, source}`,
  # `%Finch.HTTPError{reason, module, source}`, or `%Finch.Error{reason}`.
  # Bare Mint structs are never returned any more — the original
  # `%Mint.TransportError{}` / `%Mint.HTTPError{}` is nested under `:source`
  # (or nil). Timeouts surface as `%Finch.TransportError{reason: :timeout}`
  # from HTTP/1 pools and as `%Finch.Error{reason: :timeout}` (or
  # `:request_timeout`) from HTTP/2 pools.
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
    # Defensive fall-through: covers `%Finch.HTTPError{}` (protocol
    # errors), `%Finch.Error{}` with non-timeout reasons, and any future
    # unknown error term. All map to the closed-set `:transport_error`.
    # The original term is preserved in the log line so a Finch upgrade
    # that changes error shapes again is diagnosable from production
    # logs without a code change here.
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
