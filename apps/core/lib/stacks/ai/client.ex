defmodule Stacks.AI.Client do
  @moduledoc """
  HTTP client for calling the Modal vision service.

  The actual implementation is swappable via Application env:
    config :core, :vision_client, Stacks.AI.Client      # real HTTP client
    config :core, :vision_client, Stacks.AI.MockClient  # for tests

  All callers go through `call_vision/2`, which delegates to the configured module.

  ## Service-to-Service Authentication

  Requests to the Modal vision service are authenticated using a timestamp-based HMAC scheme:

    - Header: `X-Internal-Token`
    - Value: `<unix_timestamp_seconds>.<HMAC-SHA256(secret, "<ts>.<METHOD>.<path>")>` (hex-encoded)
    - Replay window: ±60 seconds (enforced by the Modal service)
    - Secret: `VISION_HMAC_SECRET` env var (shared between core and Modal vision service)
  """

  alias Stacks.AI.BudgetTracker
  alias Stacks.AI.ClientBehaviour

  @behaviour ClientBehaviour

  @fuse_name :vision_service

  @impl true
  def call_vision(endpoint, payload) do
    case configured_client() do
      __MODULE__ -> do_call_vision(endpoint, payload)
      client -> client.call_vision(endpoint, payload)
    end
  end

  @doc false
  def do_call_vision(endpoint, payload) do
    case BudgetTracker.check_budget(:modal) do
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

  @doc """
  POST /associate — asks the vision service to associate a known ISBN with a cover image.
  Returns {:ok, job_id} on success, {:error, reason} on failure.
  This is an async fire-and-forget from the vision service's perspective;
  the result arrives later via the InternalController callback.
  """
  @spec associate_isbn(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def associate_isbn(isbn, book_id, edition_id, cover_url) do
    payload = %{isbn: isbn, book_id: book_id, edition_id: edition_id, cover_url: cover_url}

    case call_vision("associate", payload) do
      {:ok, %{"job_id" => job_id}} -> {:ok, job_id}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  POST /extract — extract ISBNs from a book cover image at a URL.
  Accepts an image URL instead of a file upload.
  Returns {:ok, result_map} or {:error, reason}.
  """
  @spec extract_from_url(String.t()) :: {:ok, map()} | {:error, term()}
  def extract_from_url(image_url) do
    call_vision("extract_isbn", %{image_url: image_url})
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
  defp endpoint_path("associate"), do: "associate"
  defp endpoint_path(other), do: other

  @doc false
  def build_vision_request(path, payload) do
    base_url = Application.get_env(:core, :vision_service_url, "http://localhost:8000")
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

    start_time = System.monotonic_time()

    :telemetry.execute(
      [:stacks, :vision, :request, :start],
      %{system_time: System.system_time()},
      %{endpoint: endpoint}
    )

    # 210s gives the Modal service headroom beyond its own 300s inference timeout.
    case Finch.request(req, Stacks.Finch, receive_timeout: 210_000) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:stacks, :vision, :request, :stop],
          %{duration: duration},
          %{endpoint: endpoint, status: 200}
        )

        Jason.decode(resp_body)

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:stacks, :vision, :request, :stop],
          %{duration: duration},
          %{endpoint: endpoint, status: status}
        )

        melt_fuse(@fuse_name)
        {:error, %{status: status, body: resp_body}}

      {:error, reason} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:stacks, :vision, :request, :exception],
          %{duration: duration},
          %{endpoint: endpoint, kind: :error, reason: reason}
        )

        melt_fuse(@fuse_name)
        {:error, reason}
    end
  end

  defp melt_fuse(fuse_name) do
    :fuse.melt(fuse_name)

    case :fuse.ask(fuse_name, :sync) do
      :blown ->
        :telemetry.execute([:stacks, :fuse, :blown], %{}, %{fuse_name: fuse_name})

      _ ->
        :telemetry.execute([:stacks, :fuse, :melt], %{}, %{fuse_name: fuse_name})
    end
  end

  defp configured_client do
    Application.get_env(:core, :vision_client, __MODULE__)
  end
end
