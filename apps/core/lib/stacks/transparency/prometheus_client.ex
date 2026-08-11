defmodule Stacks.Transparency.PrometheusClient do
  @moduledoc """
  Behaviour for the transparency layer's read-only Prometheus client:
  one instant PromQL query → one scalar. Callers only pass allowlist
  queries; the behaviour exposes no caller-assembled query path. Missing
  config → `{:error, :not_configured}` and graceful degradation.
  Implementations (ADR-012 pattern): `Transparency.Prometheus` (real) and
  `MockPrometheusClient` (tests).
  """

  @doc """
  Runs a single instant PromQL query and returns its scalar value.

  Returns `{:ok, number}` on a successful query with a numeric result, or
  `{:error, reason}` (including `:not_configured` when the read token is
  absent, `:no_data` when the query matched no series, and transport errors).
  """
  @callback query(promql :: String.t()) :: {:ok, number()} | {:error, term()}
end
