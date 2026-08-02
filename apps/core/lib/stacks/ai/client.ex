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

  # ── The one deadline both sides are sized from ────────────────────────────
  #
  # Modal owns it. `apps/vision/modal_app.py` sets `timeout=300` on the
  # `@app.cls` serving every endpoint reached from here, and justifies it there
  # from the A10G's own cost structure: cold start ~60s, plus queue wait up to
  # ~120s when concurrent jobs serialise on a single GPU, plus inference ~60s.
  #
  # This constant is a MIRROR of that number, not a second opinion about it.
  # `Stacks.AI.VisionTimeoutTest` reads the decorator out of `modal_app.py` and
  # fails when the two stop agreeing, so the mirror is checked rather than
  # asserted in a comment — which is how the previous inversion survived.
  @modal_function_timeout_ms 300_000

  # Time for a response to make it back AFTER Modal's own deadline has fired.
  #
  # Modal's 300s bounds the handler's execution, not the HTTP round trip: once
  # the function times out, the platform still has to serialise an error and
  # return it through its proxy, on top of TLS setup and transit. 30s is 10% of
  # the server budget and more than three times the whole-call p50 measured in
  # #349 (8.4s), so a slow error response cannot re-invert the relationship.
  # Deliberately coarse — a slack of a few seconds would leave us one unlucky
  # round trip from the bug this constant exists to prevent.
  @transport_slack_ms 30_000

  @receive_timeout_ms @modal_function_timeout_ms + @transport_slack_ms

  @doc """
  Modal's own per-call deadline, in milliseconds — mirrored from
  `apps/vision/modal_app.py`'s `@app.cls(timeout: …)`.

  Exposed so the invariant `receive_timeout_ms() >= modal_function_timeout_ms()`
  is a statement about two named quantities that a test can make, rather than
  about two literals in different languages that a reader has to compare by eye.
  """
  @spec modal_function_timeout_ms() :: pos_integer()
  def modal_function_timeout_ms, do: @modal_function_timeout_ms

  @doc """
  The ceiling on a single vision HTTP call, in milliseconds.

  ## Why this is derived from the server's deadline, not from a percentile

  Until Issue #350 this was `210_000`, under a comment claiming it "gives the
  Modal service headroom beyond its own 300s inference timeout". 210 is less
  than 300: it gave the service *less* time, and the client hung up on calls
  Modal was still working on. The consequences compound rather than cancel — the
  GPU work continues and is billed, `Stacks.AI.VisionError.from_transport/1`
  classifies the give-up `:transient` (correctly; a lost answer says nothing
  about the image), so `Stacks.Workers.IdentifyBookJob` retries, and the retry
  queues a fresh cold start behind the same contended GPU. The inversion turned
  "slow" into "slow, three times, at triple the cost" — under exactly the load
  Modal's 300s was sized for.

  So this is not a latency budget. There is nothing useful this client can do by
  giving up while the server is still working, and only two worlds when the
  timer fires:

    * **before Modal's deadline** — an answer may still be coming. Abandoning it
      buys nothing and costs a retry.
    * **after Modal's deadline** — Modal has already given up, so no answer is
      coming and the socket is genuinely dead. Retrying is right.

  Only the second is worth acting on, which makes this a *transport liveness
  backstop* — `modal_function_timeout_ms/0` plus slack — and not a quantile of
  the latency distribution.

  ## What #349's measurement did and did not settle

  The first real distribution (n=36, one preview, ~7 minutes) put p50 at 8.4s,
  warm calls entirely under 30s and cold starts under 60s: an order of magnitude
  inside either timeout. It is tempting to read that as "both numbers are far
  too large" and cut them. Two reasons not to:

    * **every one of those samples is a call that finished.** A call that reaches
      this deadline emits `[:stacks, :vision, :request, :exception]`, never
      `:stop`, so it contributes no duration at all. That histogram is
      conditional on having received a response and structurally cannot show
      this tail — which is why the exception path is now *counted*, by
      `reason_class/1` below.
    * **the term that dominates Modal's budget was never exercised.** Most of its
      300s is queue wait, up to ~120s when concurrent uploads serialise on one
      A10G. 36 calls over 7 minutes against `max_containers: 10` never queued.
      Cutting a timeout on evidence that is silent about the condition it was
      sized for is removing a margin nobody measured.

  Raise the client to meet the server; leave the server's own number to a
  measurement that actually loads it.

  ## Who else is bound by this

  Two modules bind themselves by this function rather than restating it, after
  each had written `210_000` into a comment saying "same as the client":
  `Stacks.Moderation` bounds its per-candidate tasks, and
  `Stacks.Workers.IdentifyBookJob` bounds a whole attempt and derives the
  reader's SSE deadline from that bound. Three copies of a number that must
  agree is three chances for it to stop agreeing — so raising this moves the SSE
  ceiling with it, from a worst case of ~23 minutes to ~35. That ceiling is far
  too long for a reader either way, and shortening *this* number is not the fix:
  it buys a shorter wait by doing more GPU work, three times over. Issue #351
  decouples the reader's wait from the job's lifetime.
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

    result = Finch.request(req, Stacks.Finch, receive_timeout: @receive_timeout_ms)

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
          %{endpoint: endpoint, kind: :error, reason: reason, reason_class: reason_class(reason)}
        )

        error = VisionError.from_transport(reason)
        maybe_melt(error)
        {:error, error}
    end
  end

  @typedoc """
  The bounded vocabulary for "no answer arrived", so a transport failure can be
  counted by kind on `[:stacks, :vision, :request, :exception]`.
  """
  @type reason_class :: :timeout | :closed | :unreachable | :protocol | :other

  @doc false
  # A bounded NAME for a transport failure, because the failure itself cannot be
  # one. `reason` is an open term — a Finch struct wrapping a Mint struct, or
  # whatever else the socket layer surfaces — and must never reach a metrics
  # sink; the counter's `:tags` whitelist is what stops it, and this is what
  # gives the whitelist something worth selecting.
  #
  # The distinction that earns its keep is `:timeout` against everything else.
  # This client only reaches its own deadline once Modal has already blown past
  # its own (see `receive_timeout_ms/0`), so a non-zero `:timeout` rate is the
  # single observation that says the deadline is set wrong — and without it
  # nobody can tell whether raising it to #{@receive_timeout_ms}ms was right,
  # because a give-up emits no duration and is otherwise invisible.
  #
  # Both struct families are matched because Finch wraps Mint's errors
  # (`Finch.Error.wrap/1`) on the paths we use but not necessarily on every path
  # a future version might take; matching only the wrapper is how this would
  # quietly degrade to `:other` after a dependency bump.
  #
  # Note there is deliberately no `:pool_timeout` class. Finch's pool checkout
  # timeout RAISES rather than returning `{:error, reason}`, so it never reaches
  # this function — a clause for it would be unreachable code claiming to draw a
  # distinction it cannot draw.
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
