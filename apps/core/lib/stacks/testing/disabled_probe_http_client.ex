defmodule Stacks.Testing.DisabledProbeHttpClient do
  @moduledoc """
    `:test` default for the circuit-breaker probe transport (b).

    Refuses every request, so a probe that fires mid-suite — a fuse blown by
    one test, probed 15 s later while an unrelated test is running — cannot
    dial openlibrary.org or googleapis.com. The refusal reads as a failed
    probe: the fuse stays blown and recovers on the `{:reset, Ms}` backstop,
    which is exactly what a probe against an unreachable service would do.

    Tests that exercise probe *scheduling* keep using the
    `:circuit_breaker_probe_overrides` per-fuse seam; this module is the
    backstop for probes nothing overrode.
  """

  @behaviour Stacks.CircuitBreakers.ProbeHttpClientBehaviour

  @impl true
  def get(_url, _headers), do: {:error, :outbound_disabled_in_test}
end
