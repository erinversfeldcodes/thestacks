defmodule Stacks.CircuitBreakers.ProbeHttpClient do
  @moduledoc """
  Real probe transport for `Stacks.CircuitBreakers` — Finch, with both the
  per-chunk and whole-response bounds set (#381b/#381d).
  """

  @behaviour Stacks.CircuitBreakers.ProbeHttpClientBehaviour

  # `receive_timeout` bounds each chunk; only `request_timeout` bounds the
  # whole response, and it defaults to `:infinity` — measured in
  # `Stacks.Enrichment.RssFetcher` (a peer dribbling bytes ran 35s under a
  # "5s" receive_timeout). A probe's answer is tiny, so the same 5s bounds
  # both.
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
