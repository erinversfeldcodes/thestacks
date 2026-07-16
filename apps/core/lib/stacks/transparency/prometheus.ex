defmodule Stacks.Transparency.Prometheus do
  @moduledoc """
  Real read-only client for Fly's managed-Prometheus HTTP API (Issue #241 /
  ADR-019 §2).

  Runs a single instant query against
  `https://api.fly.io/prometheus/<org>/api/v1/query` with a read token, and
  extracts a single scalar value from the result.

  ## Token guard

  The read token (`FLY_PROMETHEUS_READ_TOKEN`) and org slug
  (`FLY_PROMETHEUS_ORG`) are Fly secrets, guarded like the log-shipper /
  Grafana config: when either is absent this client returns
  `{:error, :not_configured}` and `Stacks.Transparency` degrades the live
  section to `:unavailable`. It must never break boot or raise.

  Only queries drawn from `Stacks.Transparency`'s fixed whitelist ever reach
  this client — there is no code path that forwards a user-supplied query.
  """

  @behaviour Stacks.Transparency.PrometheusClient

  require Logger

  @default_base_url "https://api.fly.io/prometheus"
  @receive_timeout 8_000

  @impl true
  @spec query(String.t()) :: {:ok, number()} | {:error, term()}
  def query(promql) when is_binary(promql) do
    with {:ok, token} <- fetch_token(),
         {:ok, org} <- fetch_org() do
      do_query(promql, org, token)
    end
  end

  defp do_query(promql, org, token) do
    base = Application.get_env(:core, :fly_prometheus_base_url, @default_base_url)
    url = "#{base}/#{org}/api/v1/query?query=#{URI.encode_www_form(promql)}"

    req =
      Finch.build(:get, url, [
        {"Authorization", authorization(token)},
        {"Accept", "application/json"}
      ])

    case Finch.request(req, Stacks.Finch, receive_timeout: @receive_timeout) do
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

  # Fly's managed-Prometheus proxy expects the macaroon read token as the whole
  # Authorization value: `fly tokens create readonly` mints `FlyV1 fm2_…`, where
  # `FlyV1` is itself the auth scheme. Wrapping it in `Bearer ` returns 401.
  # A non-macaroon PAT still takes the `Bearer ` scheme.
  defp authorization("FlyV1" <> _ = token), do: token
  defp authorization(token), do: "Bearer #{token}"

  defp fetch_token do
    case Application.get_env(:core, :fly_prometheus_token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :not_configured}
    end
  end

  defp fetch_org do
    case Application.get_env(:core, :fly_prometheus_org) do
      org when is_binary(org) and org != "" -> {:ok, org}
      _ -> {:error, :not_configured}
    end
  end
end
