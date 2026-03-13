defmodule Stacks.Books.HttpClient do
  @moduledoc "Real HTTP client for ISBN resolver — uses Finch."

  @behaviour Stacks.Books.HttpClientBehaviour

  require Logger

  @impl true
  def get(url) do
    req = Finch.build(:get, url)

    case Finch.request(req, Stacks.Finch) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        Jason.decode(body)

      {:ok, %Finch.Response{status: status}} ->
        Logger.warning("ISBNResolver: unexpected status #{status} for #{url}")
        {:error, :unexpected_status}

      {:error, reason} ->
        Logger.warning("ISBNResolver: request failed for #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
