defmodule Stacks.CircuitBreakers.ProbeHttpClient do
  @moduledoc """
      Real probe transport for `Stacks.CircuitBreakers` — Finch, with both the
      per-chunk and whole-response bounds set (b/d).
  """

  @behaviour Stacks.CircuitBreakers.ProbeHttpClientBehaviour

  @receive_timeout 5_000
  @request_timeout 5_000

  @impl true
  def get(url, headers) do
    req = Finch.build(:get, url, headers, nil)

    case Finch.request(req, Stacks.Finch,
           receive_timeout: @receive_timeout,
           request_timeout: @request_timeout
         ) do
      {:ok, %Finch.Response{status: status}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end
end
