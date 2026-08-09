defmodule Stacks.CircuitBreakers.ProbeHttpClientBehaviour do
  @moduledoc """
  Behaviour for the circuit-breaker probe transport, swapped via
  `config :core, :circuit_breaker_probe_http_client` (#381b).

  The probes in `Stacks.CircuitBreakers` dial real third-party hosts
  (openlibrary.org, googleapis.com, api.together.xyz, …) 15 s after any fuse
  blows. Before this seam existed, that fired through bare `Finch` — so any
  test that melted a fuse and lost the `on_exit` reset race dialled the public
  internet, the exact class that produced #377 and #379. In `:test` the config
  key points at `Stacks.Testing.DisabledProbeHttpClient`, which refuses every
  request.

  The callback returns the raw status rather than interpreting it, because
  interpretation is per-probe policy, not transport: most probes require 200,
  while the R2 probe accepts any sub-500 status (an unauthenticated request to
  a healthy R2 endpoint 4xxes deterministically).
  """

  @callback get(url :: String.t(), headers :: [{String.t(), String.t()}]) ::
              {:ok, status :: non_neg_integer()} | {:error, term()}
end
