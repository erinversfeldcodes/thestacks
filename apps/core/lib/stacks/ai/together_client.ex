defmodule Stacks.AI.TogetherClient do
  @moduledoc """
  HTTP client for calling the Together AI LLM API to generate review summaries.

  The actual implementation is swappable via Application env:

      config :core, :together_client, Stacks.AI.TogetherClient         # real HTTP
      config :core, :together_client, Stacks.AI.MockTogetherClient     # tests

  ## Authentication

  Together AI uses Bearer token auth (NOT HMAC):

      Authorization: Bearer <VISION_TOGETHER_API_KEY>

  ## Circuit Breaker

  Protected by `:together_ai_fuse` — managed by `Stacks.CircuitBreakers`.
  When blown, callers should persist snapshots without a summary.
  """

  @behaviour Stacks.AI.TogetherClientBehaviour

  require Logger

  @fuse_name :together_ai_fuse

  @impl true
  def summarize_reviews(review_text, book_context) do
    case configured_client() do
      __MODULE__ -> do_summarize(review_text, book_context)
      client -> client.summarize_reviews(review_text, book_context)
    end
  end

  defp do_summarize(review_text, book_context) do
    case :fuse.ask(@fuse_name, :sync) do
      :blown -> {:error, :circuit_open}
      :ok -> make_request(review_text, book_context)
    end
  end

  defp make_request(review_text, book_context) do
    case Application.get_env(:core, :vision_together_api_key) do
      nil ->
        Logger.warning("TogetherClient: VISION_TOGETHER_API_KEY not configured")
        {:error, :api_key_missing}

      api_key ->
        send_request(review_text, book_context, api_key)
    end
  end

  defp send_request(review_text, book_context, api_key) do
    body = build_request_body(review_text, book_context)
    url = "#{base_url()}/v1/chat/completions"

    req =
      Finch.build(
        :post,
        url,
        [
          {"content-type", "application/json"},
          {"authorization", "Bearer #{api_key}"}
        ],
        body
      )

    req
    |> Finch.request(Stacks.Finch, receive_timeout: 30_000, request_timeout: 30_000)
    |> handle_response()
  end

  defp build_request_body(review_text, book_context) do
    title = Map.get(book_context, :title, "Unknown")
    author = Map.get(book_context, :author, "Unknown")

    prompt = """
    Summarize the following reviews for "#{title}" by #{author}. \
    Write a concise, balanced summary (max 500 characters) that captures \
    the consensus view. Do not invent URLs or cite sources not present \
    in the reviews. Focus on what reviewers liked, disliked, and the \
    overall sentiment.

    Reviews:
    #{review_text}
    """

    Jason.encode!(%{
      model: "meta-llama/Llama-3-8b-chat-hf",
      messages: [
        %{role: "system", content: "You are a helpful book review summarizer."},
        %{role: "user", content: prompt}
      ],
      max_tokens: 256,
      temperature: 0.3
    })
  end

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

  defp parse_success_response(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}} ->
        {:ok, String.slice(String.trim(content), 0, 500)}

      {:ok, other} ->
        Logger.warning("TogetherClient: unexpected response shape: #{inspect(other)}")
        Stacks.CircuitBreakers.melt(@fuse_name)
        {:error, {:unexpected_response, other}}
    end
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

        body =
          Jason.encode!(%{
            model: "meta-llama/Llama-3-8b-chat-hf",
            messages: [%{role: "user", content: prompt}],
            max_tokens: max_tokens,
            temperature: temperature
          })

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
