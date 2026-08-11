defmodule Stacks.CircuitBreakers.ProbeHttpClientBehaviour do
  @moduledoc """
    Behaviour for the circuit-breaker probe transport
    (`config:core,:circuit_breaker_probe_http_client`, 381b). Probes dial
    real third-party hosts 15s after a fuse blows; pre-seam this was bare
    Finch, so a test that melted a fuse could dial the public internet. In `:test` the config points at `DisabledProbeHttpClient`.
    Returns the raw status — interpretation is per-probe policy (most need
    200; R2 accepts any sub-500).
  """

  @callback get(url :: String.t(), headers :: [{String.t(), String.t()}]) ::
              {:ok, status :: non_neg_integer()} | {:error, term()}
end
