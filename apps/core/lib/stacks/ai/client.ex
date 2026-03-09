defmodule Stacks.AI.Client do
  @moduledoc """
  HTTP client for calling the vision sidecar.

  The actual implementation is swappable via Application env:
    config :core, :vision_client, Stacks.AI.Client      # real HTTP client
    config :core, :vision_client, Stacks.AI.MockClient  # for tests

  All callers go through `call_vision/2`, which delegates to the configured module.

  ## Service-to-Service Authentication

  Requests to the vision sidecar are authenticated using a timestamp-based HMAC scheme:

    - Header: `X-Internal-Token`
    - Value: `<unix_timestamp_seconds>.<HMAC-SHA256(secret, "<ts>.<METHOD>.<path>")>` (hex-encoded)
    - Replay window: ±60 seconds (enforced by the sidecar)
    - Secret: `VISION_HMAC_SECRET` env var (shared between core and vision sidecar)
  """

  alias Stacks.AI.BudgetTracker
  alias Stacks.AI.ClientBehaviour

  @behaviour ClientBehaviour

  @fuse_name :vision_sidecar

  @impl true
  def call_vision(endpoint, payload) do
    case configured_client() do
      __MODULE__ -> do_call_vision(endpoint, payload)
      client -> client.call_vision(endpoint, payload)
    end
  end

  @doc false
  def do_call_vision(endpoint, payload) do
    case BudgetTracker.check_budget(:together_ai) do
      :ok ->
        case :fuse.ask(@fuse_name, :sync) do
          :ok -> make_vision_request(endpoint, payload)
          :blown -> {:error, :circuit_open}
          # Fuse not yet installed (e.g. first startup before fuse is initialised)
          {:error, :not_found} -> make_vision_request(endpoint, payload)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp auth_token(method, path) do
    ts = System.os_time(:second) |> Integer.to_string()
    secret = Application.fetch_env!(:core, :vision_hmac_secret)
    message = "#{ts}.#{method}.#{path}"
    sig = :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode16(case: :lower)
    "#{ts}.#{sig}"
  end

  defp endpoint_path("is_book"), do: "classify"
  defp endpoint_path("extract_isbn"), do: "extract"
  defp endpoint_path(other), do: other

  @doc false
  def build_vision_request(path, payload) do
    base_url = Application.get_env(:core, :vision_sidecar_url, "http://localhost:8000")
    url = "#{base_url}#{path}"
    body = Jason.encode!(payload)

    Finch.build(
      :post,
      url,
      [{"content-type", "application/json"}, {"X-Internal-Token", auth_token("POST", path)}],
      body
    )
  end

  @doc false
  def make_vision_request(endpoint, payload) do
    path = "/#{endpoint_path(endpoint)}"
    req = build_vision_request(path, payload)

    case Finch.request(req, Stacks.Finch) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        Jason.decode(resp_body)

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        :fuse.melt(@fuse_name)
        {:error, %{status: status, body: resp_body}}

      {:error, reason} ->
        :fuse.melt(@fuse_name)
        {:error, reason}
    end
  end

  defp configured_client do
    Application.get_env(:core, :vision_client, __MODULE__)
  end
end
