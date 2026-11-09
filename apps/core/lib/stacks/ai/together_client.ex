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

  @behaviour Stacks.AI.TogetherClientBehaviour

  require Logger

  @fuse_name :together_ai_fuse

  defp handle_response({:ok, %Finch.Response{status: 200, body: resp_body}}) do
    parse_success_response(resp_body)
  end

  defp handle_response({:ok, %Finch.Response{status: status, body: resp_body}}) do
    Logger.warning("TogetherClient: HTTP #{status}: #{resp_body}")
    Stacks.CircuitBreakers.melt(@fuse_name)
    {:error, %{status: status, body: resp_body}}
  end

  defp handle_response({:error, reason}) do
    Logger.warning("TogetherClient: request failed: #{inspect(reason)}")
    Stacks.CircuitBreakers.melt(@fuse_name)
    {:error, reason}
  end

  @doc false
  # Public for one reason: so a test can observe what this does to a 200 body
  # without going through the transport. The module seam used by every other
  # test (`config :core, :together_client`) replaces `complete/2` wholesale with
  # a mock, so nothing that drives the seam can see this function at all — which
  # is how a truncation here corrupted a caller's JSON undetected. `handle_response/1`
  # is deliberately NOT exposed: it takes a `%Finch.Response{}` and would couple
  # a caller to the transport, which is the real implementation detail.
  def parse_success_response(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}} ->
        # one billable completion — the cost page counts these
        :telemetry.execute([:stacks, :ai, :together_completion], %{count: 1}, %{})

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
    case :fuse.ask(@fuse_name, :sync) do
      :blown -> {:error, :circuit_open}
      :ok -> make_completion_request(prompt, opts)
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
