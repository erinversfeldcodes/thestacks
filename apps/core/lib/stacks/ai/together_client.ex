defmodule Stacks.AI.TogetherClient do
  @moduledoc """
      HTTP client for the Together AI LLM API. Swappable via
      `config:core,:together_client` (real vs mock). Auth is
      `Authorization: Bearer <VISION_TOGETHER_API_KEY>` (not HMAC). Protected
      by `:together_ai_fuse`.

      One operation: `complete/2`, a general chat completion. Its callers are
      the blog post-book association worker and the source-scoring job.

      ⚠️ It used to carry a second operation, `summarize_reviews/2`, for review
      summaries — deleted 2026-10-15 along with the review-summary chain, which
      modelled a table holding no rows. The 500-character truncation that lived
      in `parse_success_response/1` went with it: it mirrored the review
      summary's own column cap, and it was corrupting the JSON that `complete/2`
      callers parse.
  """

  @model "meta-llama/Llama-3.3-70B-Instruct-Turbo"

  @doc """
      The model this client sends.

      ⛔ EXISTS BECAUSE THE CALL LOG RECORDED A DIFFERENT ONE. The worker logged
      `Application.get_env(:core, :together_model, "meta-llama/…")` while this
      client sent the module attribute — **two sources of truth that agreed only
      because the default string matched.** Setting that config key would have
      made `op.llm_call_log.model` attribute scores to a model the client never
      called, in the column an eval corpus is meant to group by.

      ⚖️ The same defect as the vision eval's identity one directory over, and
      the same fix: ask the thing that did the work what it did.
  """
  @spec model() :: String.t()
  def model, do: @model

  @behaviour Stacks.AI.TogetherClientBehaviour

  alias Stacks.AI.BudgetTracker

  require Logger

  @fuse_name :together_ai_fuse

  # ⚖️ 88 micro-cents per token = $0.88 per million, the most commonly cited
  # published rate for `meta-llama/Llama-3.3-70B-Instruct-Turbo` as of
  # 2026-11-09. ⚠️ Trackers disagree (0.44–1.04), and the previous default of
  # 20¢/1M was in the code with no source and set by nothing — a number nobody
  # could check. Overridable via `:core, :together_micro_cents_per_token` so a
  # confirmed rate does not need a deploy of this module; the date and the
  # spread are recorded here so the next reader knows what to re-check.
  @default_micro_cents_per_token 88

  defp handle_response({:ok, %Finch.Response{status: 200, body: resp_body}}) do
    parse_success_response(resp_body)
  end

  # ⛔ A CLIENT ERROR DOES NOT MELT THE FUSE, AND THE DISTINCTION IS NOT
  # COSMETIC.
  #
  # A circuit breaker protects against an unhealthy DEPENDENCY: it exists so a
  # service that is failing is left alone to recover. A 4xx says the opposite —
  # the dependency is fine and OUR REQUEST is wrong. Melting on one is
  # self-harm: the error is deterministic, so it recurs on every call, trips the
  # breaker, and then `do_complete/2` answers `{:error, :circuit_open}` for
  # EVERY caller of this module. One malformed request takes the whole LLM
  # boundary dark, and the logs say "circuit open" rather than what was wrong.
  #
  # ⚠️ THIS IS LIVE RISK, NOT A HYPOTHETICAL. `response_format: json_schema` was
  # just added and the schema has never been sent to the real provider —
  # Together's reference is silent on whether an array root is allowed, and
  # whether `Llama-3.3-70B-Instruct-Turbo` supports structured outputs at all is
  # unconfirmed (RL-477). If it answers 400, the old behaviour would have
  # disabled every completion in the system rather than just the one that asked
  # for a schema.
  #
  # ⚖️ 408 and 429 stay meltable: those ARE the dependency saying "not now", and
  # backing off is the correct response to both.
  defp handle_response({:ok, %Finch.Response{status: status, body: resp_body}}) do
    Logger.warning("TogetherClient: HTTP #{status}: #{resp_body}")

    if meltable?(status), do: Stacks.CircuitBreakers.melt(@fuse_name)

    {:error, %{status: status, body: resp_body}}
  end

  defp handle_response({:error, reason}) do
    Logger.warning("TogetherClient: request failed: #{inspect(reason)}")
    Stacks.CircuitBreakers.melt(@fuse_name)
    {:error, reason}
  end

  @doc false
  # ⚠️ Public so the policy can be asserted directly. `handle_response/1` takes
  # a `%Finch.Response{}` and is deliberately NOT exposed — coupling a test to
  # the transport is the thing this module's existing comment refuses — but the
  # DECISION it makes is exactly what needs a test, because getting it wrong
  # disables every caller rather than the one that erred.
  def meltable?(408), do: true
  def meltable?(429), do: true
  def meltable?(status) when status >= 400 and status < 500, do: false
  def meltable?(_), do: true

  @doc false
  # Public for one reason: so a test can observe what this does to a 200 body
  # without going through the transport. The module seam used by every other
  # test (`config :core, :together_client`) replaces `complete/2` wholesale with
  # a mock, so nothing that drives the seam can see this function at all — which
  # is how a truncation here corrupted a caller's JSON undetected. `handle_response/1`
  # is deliberately NOT exposed: it takes a `%Finch.Response{}` and would couple
  # ⛔ THE CHARGE IS MADE HERE, FROM WHAT THE RESPONSE SAYS, AND NOT BY THE
  # CALLER FROM WHAT IT GUESSED.
  #
  # This path spent money and was metered nowhere: `BudgetTracker` had one
  # caller, passing `:modal`, so every Together completion billed invisibly.
  # Charging in the client rather than in each worker means no caller can
  # forget — including the health-check smoke completion — and the seam does not
  # have to widen to carry usage back out.
  #
  # ⚠️ `usage.total_tokens` comes from the PROVIDER. A prompt-side estimate
  # would be a different number, and the one that gets billed is theirs: a
  # completion that stops early, a retried generation or a tokeniser
  # disagreement all move it. Charging from the response is what makes the
  # ledger match the invoice.
  defp charge_for(%{"usage" => %{"total_tokens" => tokens}}) when is_integer(tokens) do
    BudgetTracker.record_cost(:together, micro_cents_for_tokens(tokens))
  end

  # ⚖️ A response whose usage block we cannot read still cost something, and
  # recording nothing would make it free. One token's worth is the smallest
  # honest non-zero entry — it says "this happened" without inventing a size.
  defp charge_for(_decoded) do
    BudgetTracker.record_cost(:together, micro_cents_for_tokens(1))
  end

  # ⛔ NO CLAMP, BECAUSE THERE IS NOTHING LEFT TO ROUND. This used to be
  # `max(1, ceil(tokens * cents_per_million / 1_000_000))`, in CENTS — and a
  # cent is the wrong unit for a quantity whose natural scale is 10⁻⁵ of one. At
  # the published rate a 400-token completion costs ~0.035¢, so the clamp
  # charged it a whole cent: roughly 28× over. It bound on every call under
  # ~50,000 tokens, which is every call here except the association worker's —
  # and above ~11,400 tokens the old 20¢/1M default under-charged, asymptotically
  # by 4.4×. Both errors are gone with the unit, not with a better rounding rule.
  defp micro_cents_for_tokens(tokens) do
    rate =
      Application.get_env(:core, :together_micro_cents_per_token, @default_micro_cents_per_token)

    tokens * rate
  end

  # a caller to the transport, which is the real implementation detail.
  def parse_success_response(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]} = decoded} ->
        # one billable completion — the cost page counts these
        :telemetry.execute([:stacks, :ai, :together_completion], %{count: 1}, %{})

        charge_for(decoded)

        # ⚠️ No truncation here, deliberately, and removing it FIXED a live bug.
        #
        # This used to `String.slice(…, 0, 500)`, mirroring the 500-character cap
        # that `Enrichment.review_snapshot_changeset/2` puts on a review
        # summary — so the limit belonged to the review-summary caller and
        # travelled with it when that caller was deleted. The cap still exists
        # where it belongs: on the changeset.
        #
        # Meanwhile it was silently breaking the OTHER caller. The blog
        # post-book association worker asks for `max_tokens: 1024` and prompts
        # for a JSON array of `{book_id, confidence, reasoning}` objects over up
        # to 200 candidate books. A UUID alone is 36 characters, so two or three
        # associations with any real reasoning exceeded 500 — and the worker
        # then ran `Jason.decode/1` on JSON truncated mid-object, failed to
        # parse, logged a warning and emitted `:unreadable_response`. The
        # associations were dropped and nothing said why.
        {:ok, String.trim(content)}

      {:ok, other} ->
        Logger.warning("TogetherClient: unexpected response shape: #{inspect(other)}")
        Stacks.CircuitBreakers.melt(@fuse_name)
        {:error, {:unexpected_response, other}}

      # A 200 whose body is not JSON at all. Without this clause the `case` has
      # no match and raises `CaseClauseError` from inside the HTTP path — an
      # exception where every other failure here returns a tagged tuple, so the
      # caller's `{:error, _}` handling would be bypassed entirely. A proxy or
      # gateway error page served with status 200 is the realistic way to get
      # here.
      {:error, %Jason.DecodeError{} = error} ->
        Logger.warning("TogetherClient: 200 with undecodable body: #{inspect(error)}")
        Stacks.CircuitBreakers.melt(@fuse_name)
        {:error, {:undecodable_response, error}}
    end
  end

  # ⛔ ASKING FOR A SHAPE IS NOT THE SAME AS SURVIVING ONE.
  #
  # `:schema` makes the provider return JSON matching it, which MEASURABLY
  # changes what comes back: without it, 3 of 3 live responses arrived fenced in
  # Markdown and `Jason.decode/1` failed on every one. With it they should not.
  #
  # ⚠️ "Should not" is why `Stacks.AI.Structured` still exists and still strips
  # fences. A schema is a REQUEST to a remote model, not a guarantee from a type
  # system — a provider that ignores it, or a fallback model that does not
  # support it, must not take the association chain down. The two fixes are
  # complementary and neither is redundant: this one makes the failure rare, the
  # decoder makes it survivable.
  @doc false
  # ⚠️ PUBLIC SO IT CAN BE ASSERTED, for the same reason
  # `parse_success_response/1` is: `complete/2` delegates to
  # `configured_client()`, which in `:test` is `MockTogetherClient`, so no test
  # driving the seam can observe what the real request looks like. The mock is
  # an observability boundary, not just a substitution.
  #
  # ⛔ The alternative — asserting that the caller PASSED `:schema` — is the
  # vacuous version: it checks the option's presence rather than that anything
  # puts it on the wire, which is exactly the gap that let a 500-character
  # truncation live in the shared success path unnoticed.
  def completion_body(prompt, max_tokens, temperature, opts \\ []) do
    %{
      model: @model,
      messages: [%{role: "user", content: prompt}],
      max_tokens: max_tokens,
      temperature: temperature
    }
    |> with_output_schema(Keyword.get(opts, :schema))
  end

  defp with_output_schema(body, nil), do: body

  defp with_output_schema(body, schema) do
    Map.put(body, :response_format, %{type: "json_schema", json_schema: schema})
  end

  @impl true
  def complete(prompt, opts \\ []) do
    case configured_client() do
      __MODULE__ -> do_complete(prompt, opts)
      client -> client.complete(prompt, opts)
    end
  end

  defp do_complete(prompt, opts) do
    # ⛔ THE CHECK SITS BESIDE THE CHARGE, BECAUSE THE CHARGE IS UNIVERSAL AND
    # THE CHECK WAS NOT.
    #
    # The charge moved in here so that no caller could forget it. The ceiling
    # was then left in ONE caller — and the caller that did not have it is the
    # expensive one: the association worker asks for `max_tokens: 1024` over up
    # to 200 candidate books, with no budget reference anywhere in the module.
    # So a runaway queue could bill without limit, and the new ledger row, gauge
    # and dashboard panel would all show the spend climbing while nothing
    # refused it. A meter is not a ceiling.
    #
    # ⚠️ Checked BEFORE the fuse, deliberately: a blown fuse is a transient
    # fault worth retrying, a spent budget is not, and the caller needs to be
    # able to tell them apart to decide whether to retry.
    with :ok <- BudgetTracker.check_budget(:together),
         :ok <- :fuse.ask(@fuse_name, :sync) do
      make_completion_request(prompt, opts)
    else
      {:error, limit} when limit in [:daily_limit_exceeded, :monthly_limit_exceeded] ->
        {:error, {:budget_exceeded, limit}}

      :blown ->
        {:error, :circuit_open}
    end
  end

  defp make_completion_request(prompt, opts) do
    case Application.get_env(:core, :vision_together_api_key) do
      nil ->
        Logger.warning("TogetherClient: VISION_TOGETHER_API_KEY not configured")
        {:error, :api_key_missing}

      api_key ->
        max_tokens = Keyword.get(opts, :max_tokens, 256)
        temperature = Keyword.get(opts, :temperature, 0.3)

        body = Jason.encode!(completion_body(prompt, max_tokens, temperature, opts))

        Finch.build(
          :post,
          "#{base_url()}/v1/chat/completions",
          [
            {"content-type", "application/json"},
            {"authorization", "Bearer #{api_key}"}
          ],
          body
        )
        |> Finch.request(Stacks.Finch, receive_timeout: 30_000, request_timeout: 30_000)
        |> handle_response()
    end
  end

  defp configured_client do
    Application.get_env(:core, :together_client, __MODULE__)
  end

  defp base_url do
    Application.get_env(:core, :together_ai_base_url, "https://api.together.xyz")
  end
end
