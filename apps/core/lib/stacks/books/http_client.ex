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

      {:error, %Mint.TransportError{reason: :timeout} = reason} ->
        Logger.warning("ISBNResolver: request timed out for #{url}: #{inspect(reason)}")
        {:error, :timeout}

      {:error, %Mint.TransportError{} = reason} ->
        Logger.warning("ISBNResolver: transport error for #{url}: #{inspect(reason)}")
        {:error, :transport_error}

      {:error, reason} ->
        # Defensive fall-through: dialyzer narrows Finch's error type to
        # `Mint.TransportError.t() | Mint.HTTPError.t()`, but historically
        # some versions surfaced bare `:timeout` atoms. Map them — and
        # any future unknown error term — to the closed-set
        # `:transport_error`. The original term is preserved in the log
        # line so a Finch upgrade that reintroduces bare `:timeout` is
        # diagnosable from production logs without a code change here.
        Logger.warning("ISBNResolver: request failed for #{url}: #{inspect(reason)}")
        {:error, :transport_error}
    end
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
