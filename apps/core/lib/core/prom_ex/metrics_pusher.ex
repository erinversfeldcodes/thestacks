defmodule Core.PromEx.MetricsPusher do
  @moduledoc """
  Pushes this node's PromEx metrics to the self-hosted VictoriaMetrics store
  (ADR-021 / Epic #249 #253).

  Every `:metrics_push_interval_ms` it grabs PromEx's own Prometheus **text
  exposition** — the exact bytes `/internal/metrics` serves (`PromEx.get_metrics/1`)
  — and POSTs it to VictoriaMetrics' `/api/v1/import/prometheus` over 6PN. VM
  accepts the Prometheus text format directly, so there is no `remote_write`
  protobuf/snappy, no vmagent sidecar, and no Dockerfile change.

  ## Why push, not scrape

  Fly's managed-Prometheus scrape of a scale-to-zero app never delivered a sample
  (#248): the machine is down when the scraper calls, and a 6PN scrape doesn't
  auto-start it. Pushing runs *inside* the app, so it ships metrics while the node
  is alive and simply stops when the app scales to zero — no external actor has to
  reach a sleeping machine.

  ## The `app` label

  Raw PromEx exposition carries the app's own metric labels but NOT the `app`
  label that Fly's scrape used to add — and the dashboards filter `{app="$app"}`.
  So the push appends VM's `?extra_label=app=<app>` import param (derived from
  `FLY_APP_NAME`, same as `Stacks.Transparency`), re-creating that dimension.

  ## Configuration (fail-safe: disabled unless a target is set)

    * `config :core, :metrics_push_url` (`STACKS_METRICS_PUSH_URL`) — VM base URL,
      e.g. `http://thestacks-victoriametrics.internal:8428`. When unset the pusher
      does not start (`init/1` → `:ignore`), so local/test/CI never push.
    * `config :core, :metrics_push_interval_ms` — default #{15_000}.
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
