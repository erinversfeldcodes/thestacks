defmodule Stacks.Transparency.Prometheus do
  @moduledoc """
    Read-only client for self-hosted VictoriaMetrics: one instant query
    against `<base>/api/v1/query` (VM speaks the Prometheus API), returning
    one scalar. `<base>` is the 6PN-internal URL, unreachable publicly, so
    no token. Configured via `:metrics_query_url`; when unset (local/test)
    returns `{:error,:not_configured}` and Transparency degrades to
    `:unavailable` — never breaks boot. Only allowlist queries reach here.
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

  defp extract_value([%{"value" => [_ts, raw]} | _]), do: cast_number(raw)
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
