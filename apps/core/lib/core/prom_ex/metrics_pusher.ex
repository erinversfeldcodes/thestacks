defmodule Core.PromEx.MetricsPusher do
  @moduledoc """
    Pushes this node's PromEx metrics to self-hosted VictoriaMetrics
    (ADR-021): every `:metrics_push_interval_ms` it POSTs PromEx's own
    Prometheus text exposition to VM's `/api/v1/import/prometheus` over 6PN —
    no remote_write protobuf, no vmagent. Push (not scrape) because Fly's
    scrape of a scale-to-zero app never delivered a sample: pushing
    runs inside the app and simply stops when it sleeps. Adds the `app`
    label (`extra_labels`) that scrape infra would otherwise inject, plus
    `instance` = the Fly machine id.
  """
  use GenServer

  require Logger

  @default_interval_ms 15_000
  @import_path "/api/v1/import/prometheus"
  @prom_ex_module Core.PromEx
  @receive_timeout 10_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    case base_url() do
      nil ->
        :ignore

      base ->
        interval = Application.get_env(:core, :metrics_push_interval_ms, @default_interval_ms)
        schedule(interval)
        {:ok, %{url: build_url(base), interval: interval}}
    end
  end

  @impl GenServer
  def handle_info(:push, state) do
    push(state.url)
    schedule(state.interval)
    {:noreply, state}
  end

  @doc """
    Full import URL for a VM base — `<base>/api/v1/import/prometheus?extra_label=app=<app>`.
    Public for testability.
  """
  @spec build_url(String.t()) :: String.t()
  def build_url(base) do
    query = URI.encode_query(%{"extra_label" => "app=#{app_label()}"})
    String.trim_trailing(base, "/") <> @import_path <> "?" <> query
  end

  defp push(url) do
    case PromEx.get_metrics(@prom_ex_module) do
      metrics when is_binary(metrics) and metrics != "" -> do_post(url, metrics)
      _ -> :ok
    end
  end

  defp do_post(url, metrics) do
    req = Finch.build(:post, url, [{"content-type", "text/plain"}], metrics)

    case Finch.request(req, Stacks.Finch,
           receive_timeout: @receive_timeout,
           request_timeout: @receive_timeout
         ) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Finch.Response{status: status}} ->
        Logger.warning("MetricsPusher: VictoriaMetrics import returned HTTP #{status}")

      {:error, reason} ->
        Logger.warning("MetricsPusher: push failed: #{inspect(reason)}")
    end
  end

  defp schedule(interval), do: Process.send_after(self(), :push, interval)

  defp base_url do
    case Application.get_env(:core, :metrics_push_url) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  defp app_label do
    Application.get_env(
      :core,
      :fly_metrics_app,
      System.get_env("FLY_APP_NAME") || "thestacks-core"
    )
  end
end
