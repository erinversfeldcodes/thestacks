defmodule Stacks.Transparency.Prometheus do
  @moduledoc """
  Read-only client for the self-hosted VictoriaMetrics store (ADR-021 / #241 / #255).

  Runs a single instant query against `<base>/api/v1/query` — VictoriaMetrics
  speaks the Prometheus query API — and extracts a single scalar from the result.
  `<base>` is the 6PN-internal VM URL (e.g.
  `http://thestacks-victoriametrics.internal:8428`), so **no auth/token** is
  needed: the endpoint is unreachable from the public internet. This replaces the
  Fly managed-Prometheus client, whose scrape never ingested a sample (#248).

  ## Config guard

  The base URL comes from `config :core, :metrics_query_url` (runtime.exs defaults
  it to the metrics push target — the same VM). When unset — local/test — this
  client returns `{:error, :not_configured}` and `Stacks.Transparency` degrades
  the live section to `:unavailable`. It must never break boot or raise.

  Only queries drawn from `Stacks.Transparency`'s fixed allowlist ever reach this
  client — there is no code path that forwards a user-supplied query — and the
  allowlist is proven a subset of `Core.PromEx.MetricAudience` `:public` metrics.
  """

  @behaviour Stacks.Transparency.PrometheusClient

  require Logger

  @receive_timeout 8_000

  @impl true
  @spec query(String.t()) :: {:ok, number()} | {:error, term()}
  def query(promql) when is_binary(promql) do
    with {:ok, base} <- fetch_base_url() do
      do_query(promql, base)
    end
  end

  defp do_query(promql, base) do
    url = "#{base}/api/v1/query?query=#{URI.encode_www_form(promql)}"

    req = Finch.build(:get, url, [{"Accept", "application/json"}])

    # request_timeout bounds the WHOLE response (receive_timeout is
    # per-chunk — #381d); an instant-query scalar is tiny.
    case Finch.request(req, Stacks.Finch,
           receive_timeout: @receive_timeout,
           request_timeout: @receive_timeout
         ) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        parse_scalar(body)

      {:ok, %Finch.Response{status: status}} ->
        Logger.warning("Transparency.Prometheus: unexpected status #{status}")
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        Logger.warning("Transparency.Prometheus: request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Prometheus instant-query response:
  #   {"status":"success","data":{"resultType":"vector",
  #     "result":[{"metric":{...},"value":[<ts>,"<scalar>"]}]}}
  # A scalar result type is {"resultType":"scalar","result":[<ts>,"<scalar>"]}.
  defp parse_scalar(body) do
    case Jason.decode(body) do
      {:ok, %{"status" => "success", "data" => %{"result" => result}}} ->
        extract_value(result)

      {:ok, _} ->
        {:error, :no_data}

      {:error, reason} ->
        {:error, {:json_decode_error, reason}}
    end
  end

  # Vector: take the first series' sample value.
  defp extract_value([%{"value" => [_ts, raw]} | _]), do: cast_number(raw)
  # Scalar: [ts, "value"].
  defp extract_value([_ts, raw]) when is_binary(raw), do: cast_number(raw)
  defp extract_value(_), do: {:error, :no_data}

  defp cast_number(raw) when is_binary(raw) do
    case Float.parse(raw) do
      {n, _} -> {:ok, n}
      :error -> {:error, :non_numeric}
    end
  end

  defp fetch_base_url do
    case Application.get_env(:core, :metrics_query_url) do
      url when is_binary(url) and url != "" -> {:ok, String.trim_trailing(url, "/")}
      _ -> {:error, :not_configured}
    end
  end
end
