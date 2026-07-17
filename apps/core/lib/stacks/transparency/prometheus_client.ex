defmodule Stacks.Transparency.PrometheusClient do
  @moduledoc """
  Behaviour for the read-only Prometheus client used by the public
  transparency data layer (Issue #241 / ADR-019).

  The single callback runs ONE instant PromQL query and returns a scalar
  numeric value. Callers (`Stacks.Transparency`) only ever pass queries drawn
  from the fixed, code-defined allowlist — the behaviour deliberately exposes
  no way to run a caller-assembled query beyond that allowlist. The
  implementation guards Fly's managed-Prometheus read token: when the token is
  absent the client returns `{:error, :not_configured}` and the live section
  degrades to `:unavailable` rather than erroring or leaking.

  Two implementations follow the ADR-012 behaviour-mock pattern:

    * `Stacks.Transparency.Prometheus` — real HTTP client against Fly's
      managed-Prometheus `/api/v1/query` endpoint (default in dev/prod).
    * `Stacks.Transparency.MockPrometheusClient` — process-dictionary mock
      wired in `config/test.exs`.
  """

  @doc """
  Runs a single instant PromQL query and returns its scalar value.

  Returns `{:ok, number}` on a successful query with a numeric result, or
  `{:error, reason}` (including `:not_configured` when the read token is
  absent, `:no_data` when the query matched no series, and transport errors).
  """
  @callback query(promql :: String.t()) :: {:ok, number()} | {:error, term()}
end
