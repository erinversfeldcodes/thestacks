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

  alias Stacks.AI.Budget
  alias Stacks.AI.ClientBehaviour
  alias Stacks.AI.VisionError
  alias Stacks.Costs

  @behaviour ClientBehaviour

  @fuse_name :vision_fuse

  # The ledger is denominated in micro-cents; this config value is in cents.
  @micro_cents_per_cent 100_000

  # The tiers this build knows. A label outside this set collapses to "other".
  @known_tiers [
    "ANALYSIS_TIER_UNSPECIFIED",
    "ANALYSIS_TIER_BARCODE",
    "ANALYSIS_TIER_VLM_CLASSIFY",
    "ANALYSIS_TIER_VLM_EXTRACT"
  ]

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
    case Budget.check_budget(:modal) do
      :ok ->
        case :fuse.ask(@fuse_name, :sync) do
          :ok -> make_vision_request(endpoint, payload)
          :blown -> {:error, :circuit_open}
        end

      {:error, _daily_or_monthly} ->
        {:error, :budget_exceeded}
    end
  end

  defp auth_token(method, path) do
    ts = System.os_time(:second) |> Integer.to_string()
    secret = Application.fetch_env!(:core, :vision_hmac_secret)
    message = "#{ts}.#{method}.#{path}"
    sig = :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode16(case: :lower)
    "#{ts}.#{sig}"
  end

  # `/analyze` is the ONE endpoint the sidecar serves. Two caller-facing
  # operation names still resolve to it, which is deliberate: the name says what
  # the caller is asking, the path says who answers.
  #
  # ⚠️ "is_book" mapped to `/classify` until 2026-10-15. That endpoint is gone,
  # so the mapping had become a route to a 404. ⚠️ The 404 was not what made it
  # harmless, and saying so would understate it: the single production caller is
  # `blow_all_fuses/1`, which sets `vision_service_url` to `http://localhost:1`
  # BEFORE calling, so the probe never reaches a server and the resolved path
  # never mattered. Pointing it at `/analyze` keeps the question askable and
  # stops the table describing a service that no longer exists.
  #
  # ⚠️ Do NOT collapse this to a single `endpoint_path(_), do: "analyze"`. The
  # catch-all raise below is load-bearing: an unrecognised operation must fail at
  # the call site rather than silently reach a real endpoint, and a test pins it.
  defp endpoint_path("is_book"), do: "analyze"
  defp endpoint_path("analyze"), do: "analyze"

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

    # ⛔ CHARGED UNCONDITIONALLY AND THEN ADJUSTED, rather than charged after
    # the parse — because a request that errored STILL COST GPU TIME. The
    # container ran; only the answer was lost. Charging only on success would
    # make a failing model free, which is the direction that under-counts, and
    # a test pins that behaviour deliberately.
    #
    # ⚖️ So the baseline is taken here and the tier-specific difference is
    # settled below once the response says which tier answered. A call whose
    # tier we never learn keeps the baseline, which is the honest reading: we
    # know it cost something and not what.
    record_vision_call_cost()

    case result do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:stacks, :vision, :request, :stop],
          %{duration: duration},
          %{endpoint: endpoint, status: 200}
        )

        charge_and_report_tier(resp_body)

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

  # ⛔ CONVERTED, BECAUSE THE LEDGER'S UNIT CHANGED UNDER THIS CALLER AND NOTHING
  # HERE NOTICED.
  #
  # `Budget.record_cost/2` moved from cents to MICRO-cents when the spend
  # ledger was re-denominated — token pricing is quoted per million, and a cent
  # cannot express the cost of a short completion. This call site kept passing a
  # cents-denominated config value, so **every Modal call charged 1 micro-cent
  # instead of 1 cent and the daily 500¢ ceiling needed 50,000,000 calls to
  # trip. The Modal budget was effectively unenforced.**
  #
  # ⚠️ The config key is named `_cents` and stays that way: a price a person
  # sets should be written in the unit a person thinks in. The conversion
  # belongs here, at the boundary between that decision and the ledger's
  # precision — not in the key's name.
  defp record_vision_call_cost do
    # ⛔ READ FROM `Costs`, WHICH OWNS THE PRICE. This used to default to its
    # own `@default_modal_cost_per_call_cents 1` while `Costs` billed the
    # public page at 3 — and nothing configured the override, so the budget
    # guard charged a third of what the page claimed. The config key is still
    # honoured for an operator who needs to override, but its default is now
    # the one number rather than a second opinion about it.
    cost_cents =
      Application.get_env(:core, :modal_cost_per_call_cents, Costs.modal_per_inference_cents())

    Budget.record_cost(:modal, cost_cents * @micro_cents_per_cent)
  end

  # ⛔ THE TIER IS READ FROM THE RESPONSE, NOT ASSUMED. Charging a flat rate
  # per call made a CPU barcode decode and a 7B VLM inference indistinguishable
  # in the ledger — which is the figure the vision redesign's cost case is
  # argued from.
  #
  # ⚖️ Parsed leniently and on purpose: a sidecar that has not been redeployed
  # yet sends no `tier`, and the honest response to that is the baseline
  # charge plus an `unspecified` label — not a crash, and not a guessed
  # surcharge.
  defp charge_and_report_tier(resp_body) do
    tier =
      case Jason.decode(resp_body) do
        {:ok, %{"tier" => tier}} when is_binary(tier) and tier != "" -> tier
        _ -> "ANALYSIS_TIER_UNSPECIFIED"
      end

    surcharge = tier_surcharge_micro_cents(tier)

    if surcharge > 0 do
      Budget.record_cost(:modal, surcharge)
    end

    # ⚠️ The label is bounded HERE, at the emit site, against the tiers this
    # build knows. A sidecar ahead of this deployment could send a tier name
    # nothing here declares, and `tier` is a string off the wire — an
    # unbounded label on a metric is a cardinality commitment to the store that
    # whoever deploys the sidecar never agreed to make.
    :telemetry.execute(
      [:stacks, :vision, :tier],
      %{count: 1},
      %{tier: bounded_tier(tier), cold: cold_label(resp_body)}
    )
  end

  # ⚖️ Anything undeclared collapses to "other" rather than reaching the store,
  # and the visible under-labelling is the signal to come and declare it —
  # the same rule every other bounded label in this app follows.
  defp bounded_tier(tier) when tier in @known_tiers, do: tier
  defp bounded_tier(_), do: "other"

  defp cold_label(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"sidecar_cold" => true}} -> "cold"
      {:ok, %{"sidecar_cold" => false}} -> "warm"
      _ -> "unknown"
    end
  end

  @doc false
  @spec tier_surcharge_micro_cents(String.t() | nil) :: non_neg_integer()
  def tier_surcharge_micro_cents(tier)

  # ⛔ THE BARCODE TIER DID NOT RUN THE GPU, SO IT MUST NOT BE BILLED AS IF IT
  # HAD — and until the response carried a tier, every call was charged the
  # same flat rate regardless.
  #
  # ⚖️ A SURCHARGE on top of the baseline, not a replacement for it. The
  # baseline is already recorded before the parse, so this adds only the
  # difference a GPU inference costs beyond a CPU barcode decode. That keeps
  # the "a failed call still charges" guarantee intact while making a barcode
  # hit cost what a barcode hit costs.
  #
  # ⚠️ Zero for a tier this build has not been taught. Guessing a surcharge for
  # an unknown tier would bill for work we cannot describe; under-charging a
  # new tier is visible as a ledger that lags the invoice, which is the
  # direction someone notices.
  def tier_surcharge_micro_cents("ANALYSIS_TIER_BARCODE"), do: 0

  def tier_surcharge_micro_cents(tier)
      when tier in ["ANALYSIS_TIER_VLM_CLASSIFY", "ANALYSIS_TIER_VLM_EXTRACT"] do
    Costs.modal_gpu_inference_surcharge_cents() * @micro_cents_per_cent
  end

  def tier_surcharge_micro_cents(_unknown), do: 0

  defp configured_client do
    Application.get_env(:core, :vision_client, __MODULE__)
  end
end
