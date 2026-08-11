defmodule Stacks.AI.Client do
  @moduledoc """
      HTTP client for the Modal vision service. Wire contract:
      `proto/stacks/internal/v1/vision.proto`. Swappable via
      `config:core,:vision_client` (real vs `MockClient`); all callers go
      through `call_vision/2`.

      Auth: timestamp-based HMAC in `X-Internal-Token` —
      `<unix_ts>.<HMAC-SHA256(secret, "<ts>.<METHOD>.<path>")>`, ±60s replay
      window, secret in `VISION_HMAC_SECRET`.

      Failures are members of `Stacks.AI.VisionError.t/0` (closed set), so
      callers can distinguish a determination about the image from a transient
      fault.
  """

  alias Stacks.AI.BudgetTracker
  alias Stacks.AI.ClientBehaviour
  alias Stacks.AI.VisionError
  alias Stacks.Proto.Vision.AssociateRequest
  alias Stacks.Proto.Vision.ExtractRequest

  @behaviour ClientBehaviour

  @fuse_name :vision_fuse
  @default_modal_cost_per_call_cents 1

  @modal_function_timeout_ms 300_000

  @transport_slack_ms 30_000

  @receive_timeout_ms @modal_function_timeout_ms + @transport_slack_ms

  @doc """
      Modal's own per-call deadline, in milliseconds — mirrored from
      `apps/vision/modal_app.py`'s `@app.cls(timeout: …)`.

      Exposed so the invariant `receive_timeout_ms >= modal_function_timeout_ms`
      is a statement about two named quantities that a test can make, rather than
      about two literals in different languages that a reader has to compare by eye.
  """
  @spec modal_function_timeout_ms() :: pos_integer()
  def modal_function_timeout_ms, do: @modal_function_timeout_ms

  @doc """
      Ceiling on a single vision HTTP call, in ms — DERIVED as Modal's own
      300s inference deadline plus slack, never a smaller "latency budget".
      Pre-350 this was 210s (< 300s): the client hung up on calls Modal was
      still working on, the GPU work continued and was billed, the give-up was
      classified `:transient`, and the retry queued a fresh cold start behind
      the same contended GPU. Giving up before the server's deadline buys
      nothing; after it, Modal has already answered 504.
  """
  @spec receive_timeout_ms() :: pos_integer()
  def receive_timeout_ms, do: @receive_timeout_ms

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

    result =
      Finch.request(req, Stacks.Finch,
        receive_timeout: @receive_timeout_ms,
        request_timeout: @receive_timeout_ms
      )

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
          %{endpoint: endpoint, kind: :error, reason: reason, reason_class: reason_class(reason)}
        )

        error = VisionError.from_transport(reason)
        maybe_melt(error)
        {:error, error}
    end
  end

  @typedoc """
    The bounded vocabulary for "no answer arrived", so a transport failure can be
    counted by kind on `[:stacks,:vision,:request,:exception]`.
  """
  @type reason_class :: :timeout | :closed | :unreachable | :protocol | :other

  @doc false
  @spec reason_class(term()) :: reason_class()
  def reason_class(%Finch.TransportError{reason: reason}), do: transport_class(reason)
  def reason_class(%Mint.TransportError{reason: reason}), do: transport_class(reason)
  def reason_class(%Finch.HTTPError{}), do: :protocol
  def reason_class(%Mint.HTTPError{}), do: :protocol
  def reason_class(_other), do: :other

  defp transport_class(:timeout), do: :timeout
  defp transport_class(:closed), do: :closed

  defp transport_class(reason)
       when reason in [:econnrefused, :nxdomain, :ehostunreach, :enetunreach, :ehostdown],
       do: :unreachable

  defp transport_class(_other), do: :other

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
