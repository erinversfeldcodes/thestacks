defmodule Stacks.AI.Client do
  @moduledoc """
  HTTP client for calling the Modal vision service.

  Wire contract: `proto/stacks/internal/v1/vision.proto`
  (ClassifyRequest/Response, ExtractRequest/Response, AssociateRequest/Response/Callback)

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

  ## Failure contract

  `call_vision/2` fails with a member of `Stacks.AI.VisionError.t/0` — a closed
  set, so a caller can ask whether the failure was a determination about the
  image (never retry) or a fault (retry). Before that type existed, callers saw
  `:circuit_open`, a raw `%Finch.Error{}`, and a `%{status: _, body: _}` map,
  which is why every vision failure was retried three times on a GPU.

  ## Circuit Breaker

  Protected by `:vision_fuse` — managed by `Stacks.CircuitBreakers`.
  When blown, `call_vision/2` returns `{:error, :circuit_open}`. Only transient
  failures melt it: see `maybe_melt/1`.

  ## Cost Tracking

  Every Finch request to the vision service charges a fixed per-call cost to
  `BudgetTracker` under the `:modal` provider key. The cost is incurred whether
  the response is success, non-200, or transport error — Modal bills for GPU
  time regardless of whether we end up using the result.

  The per-call amount defaults to 1 cent and is configurable via
  `config :core, :modal_cost_per_call_cents`. This is a coarse approximation;
  precise per-call billing arrives via `RefreshCostsJob` reading the Modal
  usage API. The BudgetTracker counter exists to enforce the daily/monthly
  budget cap in real time and to surface a non-zero number on the cost
  dashboard between RefreshCostsJob runs.
  """

  alias Stacks.AI.BudgetTracker
  alias Stacks.AI.ClientBehaviour
  alias Stacks.AI.VisionError
  alias Stacks.Proto.Vision.AssociateRequest
  alias Stacks.Proto.Vision.ExtractRequest

  @behaviour ClientBehaviour

  @fuse_name :vision_fuse
  @default_modal_cost_per_call_cents 1

  @impl true
  def call_vision(endpoint, payload) do
    case configured_client() do
      __MODULE__ -> do_call_vision(endpoint, payload)
      client -> client.call_vision(endpoint, payload)
    end
  end

  defp do_call_vision(endpoint, payload) do
    case BudgetTracker.check_budget(:modal) do
      :ok ->
        case :fuse.ask(@fuse_name, :sync) do
          :ok -> make_vision_request(endpoint, payload)
          :blown -> {:error, :circuit_open}
        end

      # Both limits collapse to one reason on purpose. Which cap was hit is a
      # spend question, already logged and counted by BudgetTracker; to a caller
      # it is the same fact — no request will be made, and that will still be
      # true a few seconds from now.
      {:error, _daily_or_monthly} ->
        {:error, :budget_exceeded}
    end
  end

  @doc """
  POST /associate — asks the vision service to associate a known ISBN with a cover image.
  Returns {:ok, job_id} on success, {:error, reason} on failure.

  Delegates to `call_vision/2`, so the configured client (real or mock) is always respected.
  Request/response shape: `AssociateRequest` / `AssociateResponse` in vision.proto.
  The result arrives later via the InternalController callback (`AssociateCallback`).
  """
  @spec associate_isbn(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def associate_isbn(isbn, book_id, edition_id, cover_image_url) do
    payload = %AssociateRequest{
      isbn: isbn,
      book_id: book_id,
      edition_id: edition_id,
      cover_image_url: cover_image_url
    }

    case call_vision("associate", payload) do
      {:ok, %{"job_id" => job_id}} -> {:ok, job_id}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  POST /extract — extract ISBNs from a book cover image at a URL.
  Delegates to `call_vision/2`, so the configured client (real or mock) is always respected.
  """
  @spec extract_from_url(String.t()) :: {:ok, map()} | {:error, term()}
  def extract_from_url(image_url) do
    case call_vision("extract_isbn", %ExtractRequest{image_url: image_url}) do
      {:ok, %{"books" => _} = resp} -> {:ok, resp}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, _} = err -> err
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
  # Single-request classify + extract — the vision service composes both
  # steps and short-circuits on non-books internally. Prefer this over
  # calling "is_book" and "extract_isbn" separately; see
  # Stacks.Moderation.run_pipeline/1.
  defp endpoint_path("analyze"), do: "analyze"
  defp endpoint_path("associate"), do: "associate"

  defp endpoint_path(other) do
    raise ArgumentError, "unknown vision endpoint: #{inspect(other)}"
  end

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

  defp make_vision_request(endpoint, payload) do
    path = "/#{endpoint_path(endpoint)}"
    req = build_vision_request(path, payload)

    start_time = System.monotonic_time()

    :telemetry.execute(
      [:stacks, :vision, :request, :start],
      %{system_time: System.system_time()},
      %{endpoint: endpoint}
    )

    # 210s gives the Modal service headroom beyond its own 300s inference timeout.
    result = Finch.request(req, Stacks.Finch, receive_timeout: 210_000)

    # Record the per-call cost regardless of outcome. Rejection ≠ free —
    # Modal bills for GPU time whether or not we use the result.
    record_vision_call_cost()

    case result do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:stacks, :vision, :request, :stop],
          %{duration: duration},
          %{endpoint: endpoint, status: 200}
        )

        decode_success_body(resp_body)

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:stacks, :vision, :request, :stop],
          %{duration: duration},
          %{endpoint: endpoint, status: status}
        )

        error = VisionError.from_http_error(status, resp_body)
        maybe_melt(error)
        {:error, error}

      {:error, reason} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:stacks, :vision, :request, :exception],
          %{duration: duration},
          %{endpoint: endpoint, kind: :error, reason: reason}
        )

        error = VisionError.from_transport(reason)
        maybe_melt(error)
        {:error, error}
    end
  end

  # A 200 we cannot parse is not a success. It is also not a determination about
  # the image — the service never told us anything — so it is reported as the
  # transport failure it functionally is, and stays retryable.
  defp decode_success_body(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, _} ->
        error = VisionError.from_transport(:malformed_response)
        maybe_melt(error)
        {:error, error}
    end
  end

  # The breaker exists to stop us hammering a service that is unwell. A
  # deterministic rejection says nothing about the service's health — it says
  # our image was unreadable, and the service told us so promptly and
  # correctly. Melting on it would let a run of corrupt uploads disable vision
  # for everybody, which is exactly the trap `SCRAPE_OUTCOME_ROBOTS_BLOCKED` was
  # split out of the scraper's shared fuse to avoid.
  defp maybe_melt(error) do
    case VisionError.determination(error) do
      :transient -> Stacks.CircuitBreakers.melt(@fuse_name)
      :deterministic -> :ok
    end
  end

  defp record_vision_call_cost do
    cost_cents =
      Application.get_env(:core, :modal_cost_per_call_cents, @default_modal_cost_per_call_cents)

    BudgetTracker.record_cost(:modal, cost_cents)
  end

  defp configured_client do
    Application.get_env(:core, :vision_client, __MODULE__)
  end
end
