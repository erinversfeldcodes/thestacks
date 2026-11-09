defmodule Stacks.AI.TogetherClientParseTest do
  @moduledoc """
      What a Together AI 200 body becomes, asserted directly on the parser.

      ⚠️ This file exists because of a defect that shipped and a test that could
      not see it. `parse_success_response/1` used to end in
      `String.slice(content, 0, 500)`. That cap mirrored the review summary's own
      column limit, but it lived in the SHARED success path — so it also applied
      to the blog post-book association worker, which asks for `max_tokens: 1024`
      and prompts for a JSON array of `{book_id, confidence, reasoning}` objects.
      A UUID alone is 36 characters, so a handful of associations exceeded 500,
      the JSON arrived cut mid-object, `Jason.decode/1` failed, and every
      association was dropped while the job returned `:ok`.

      The first attempt to pin that down was written against `complete/2` and was
      VACUOUS: `complete/2` delegates to `configured_client()`, which in `:test`
      is `MockTogetherClient`, so the real parser never ran. The mock seam is an
      observability boundary, not just a substitution — no test that drives the
      seam can observe anything the real implementation does behind it.

      Hence: test the parser, not the transport. Every assertion below is about
      the one thing a caller depends on — that the content it gets back can
      still be parsed.
  """

  # ⚠️ DataCase: the success path now charges the durable budget ledger, so
  # these tests need a sandboxed connection.
  use Core.DataCase, async: false

  alias Stacks.AI.Spend
  alias Stacks.AI.Structured
  alias Stacks.AI.TogetherClient

  # Four associations with realistic UUIDs and reasoning: the shape the blog
  # worker actually prompts for, long enough to have been destroyed by the old
  # cap.
  defp association_payload do
    Jason.encode!([
      %{
        "book_id" => "0f8c4e2a-1b3d-4f5e-8a7b-9c0d1e2f3a4b",
        "confidence" => 0.91,
        "reasoning" => "The post discusses this edition's translation at length."
      },
      %{
        "book_id" => "1a9d5f3b-2c4e-5a6f-9b8c-0d1e2f3a4b5c",
        "confidence" => 0.74,
        "reasoning" => "Named in passing as a comparison to the main subject."
      },
      %{
        "book_id" => "2b0e6a4c-3d5f-6b7a-0c9d-1e2f3a4b5c6d",
        "confidence" => 0.63,
        "reasoning" => "The author's earlier work, referenced in the closing paragraph."
      },
      %{
        "book_id" => "3c1f7b5d-4e6a-7c8b-1d0e-2f3a4b5c6d7e",
        "confidence" => 0.55,
        "reasoning" => "Mentioned once in a list of recommendations at the end."
      }
    ])
  end

  defp envelope(content) do
    Jason.encode!(%{"choices" => [%{"message" => %{"content" => content}}]})
  end

  defp capture_telemetry(event, fun) do
    handler_id = "together-parse-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn ^event, measurements, _metadata, _ ->
          # Only this process's events. Without the filter a concurrent test
          # emitting the same event would satisfy the assertion.
          if self() == test_pid, do: send(test_pid, {:telemetry, measurements})
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  describe "parse_success_response/1 — the content a caller receives" do
    test "a long association array survives whole and is still parseable" do
      payload = association_payload()

      # ⚠️ The anti-vacuity guard. If a future tidy-up shortens the reasoning
      # strings below 500 bytes, this test silently stops exercising the bug it
      # was written for. Fail loudly instead.
      assert byte_size(payload) > 500,
             "fixture no longer exceeds the old 500-byte cap (#{byte_size(payload)} bytes), " <>
               "so it cannot detect a truncation regression"

      assert {:ok, content} = TogetherClient.parse_success_response(envelope(payload))

      # The property that actually broke: the caller can still parse it. This
      # fails under a truncation at ANY limit, not just 500.
      assert decoded = Jason.decode!(content)
      assert length(decoded) == 4

      assert Enum.map(decoded, & &1["book_id"]) == [
               "0f8c4e2a-1b3d-4f5e-8a7b-9c0d1e2f3a4b",
               "1a9d5f3b-2c4e-5a6f-9b8c-0d1e2f3a4b5c",
               "2b0e6a4c-3d5f-6b7a-0c9d-1e2f3a4b5c6d",
               "3c1f7b5d-4e6a-7c8b-1d0e-2f3a4b5c6d7e"
             ]

      # Exact equality, which is strictly sharper than a length check: a parser
      # that mangled the middle would pass on bytes and fail here.
      assert content == payload
    end

    test "surrounding whitespace is trimmed, and nothing else is" do
      payload = association_payload()

      assert {:ok, content} =
               TogetherClient.parse_success_response(envelope("\n  " <> payload <> "  \n"))

      assert content == payload
    end

    test "one billable completion is counted per successful parse" do
      # The counter the cost page reads. Nothing asserted this anywhere before.
      capture_telemetry([:stacks, :ai, :together_completion], fn ->
        assert {:ok, _} = TogetherClient.parse_success_response(envelope(association_payload()))
      end)

      assert_received {:telemetry, %{count: 1}}
      refute_received {:telemetry, _}, "expected exactly one completion event per parse"
    end

    test "a 200 whose body is not JSON returns an error rather than raising" do
      # Served by a proxy or gateway error page. Before the decode-error clause
      # existed this raised CaseClauseError from inside the HTTP path, bypassing
      # every caller's {:error, _} handling.
      assert {:error, {:undecodable_response, %Jason.DecodeError{}}} =
               TogetherClient.parse_success_response("<html>502 Bad Gateway</html>")
    end

    test "a 200 with an unexpected JSON shape returns a tagged error" do
      assert {:error, {:unexpected_response, %{"error" => _}}} =
               TogetherClient.parse_success_response(Jason.encode!(%{"error" => "quota"}))
    end
  end

  describe "the request body" do
    # ⛔ ASSERTED ON THE BODY, NOT ON THE OPTION. MEASURED against the live
    # model before this landed: 3 of 3 responses came back fenced in Markdown
    # because nothing told the provider what shape to answer in. A test that
    # checked the CALLER passed `:schema` would have passed against a client
    # that dropped it on the floor.
    test "a schema reaches the wire as a json_schema response_format" do
      schema = Structured.association_schema()

      body = TogetherClient.completion_body("find books", 1024, 0.2, schema: schema)

      assert %{type: "json_schema", json_schema: ^schema} = body.response_format
    end

    # ⚖️ ANTI-VACUITY, and it is the half that makes the case above mean
    # something: without it, a client that attached `response_format`
    # unconditionally would pass. A caller wanting free text must still get it.
    test "no schema means no response_format at all" do
      body = TogetherClient.completion_body("summarise this", 256, 0.3)

      refute Map.has_key?(body, :response_format),
             "a completion with no schema must not ask the provider for JSON — " <>
               "the review summariser wants prose"
    end

    test "the rest of the request is unchanged by the schema" do
      with_schema =
        TogetherClient.completion_body("p", 1024, 0.2, schema: Structured.association_schema())

      assert with_schema.max_tokens == 1024
      assert with_schema.temperature == 0.2
      assert [%{role: "user", content: "p"}] = with_schema.messages
    end
  end

  describe "which failures melt the circuit breaker" do
    # ⛔ A CLIENT ERROR MUST NOT TRIP THE BREAKER. A 4xx says the dependency is
    # healthy and OUR request is wrong — deterministic, so it recurs on every
    # call, trips the fuse, and then every caller of this module gets
    # `{:error, :circuit_open}`. One malformed request takes the whole LLM
    # boundary dark, and the logs say "circuit open" instead of what was wrong.
    #
    # ⚠️ Live risk when this was written: `response_format: json_schema` had
    # just been added and had never been sent to the real provider. A 400 on an
    # unsupported schema would have disabled every completion in the system
    # rather than just the one asking for a schema.
    test "a 400 — an invalid schema, say — does not melt" do
      refute TogetherClient.meltable?(400),
             "a rejected request must not trip the breaker for everyone else"
    end

    test "nor a 401, 404 or 422" do
      refute TogetherClient.meltable?(401)
      refute TogetherClient.meltable?(404)
      refute TogetherClient.meltable?(422)
    end

    # ⚖️ ANTI-VACUITY, and it is the half that makes the cases above mean
    # something: a `meltable?/1` that answered false for everything would pass
    # them while disabling the breaker entirely.
    test "a 500 still melts — that IS the dependency failing" do
      assert TogetherClient.meltable?(500)
      assert TogetherClient.meltable?(503)
    end

    # ⚖️ The two 4xx codes that mean "not now" rather than "not like that".
    # Backing off is the correct response to both.
    test "408 and 429 melt, because they are the dependency saying wait" do
      assert TogetherClient.meltable?(408)
      assert TogetherClient.meltable?(429)
    end
  end

  describe "what the completion is charged" do
    # ⛔ THE CHARGE FOLLOWS THE RESPONSE, NOT A PROMPT-SIDE ESTIMATE.
    #
    # This path billed invisibly: `BudgetTracker` had one caller passing
    # `:modal`, so every Together completion spent unmetered. The number that
    # matters is the provider's — a completion that stops early, a retried
    # generation or a tokeniser disagreement all move it away from anything the
    # caller could have guessed from the prompt.
    #
    # ⚠️ MICRO-CENTS, AND THE UNIT IS LOAD-BEARING. These were written in cents
    # with a `max(1, ceil(…))` clamp, which over-charged a 400-token call by
    # ~28× and under-charged a large one by up to 4.4×. The clamp is gone
    # because the unit removed the rounding, so the arithmetic below is exact.
    test "the charge comes from usage.total_tokens, not from the prompt's size" do
      # A tiny prompt and a tiny answer, with a provider-reported usage far
      # larger than either — the disagreement is the point of the case.
      body =
        Jason.encode!(%{
          "choices" => [%{"message" => %{"content" => "0.8"}}],
          "usage" => %{"total_tokens" => 2_000_000}
        })

      assert {:ok, "0.8"} = TogetherClient.parse_success_response(body)

      charged = Spend.spent(:together, :daily)

      assert charged == 2_000_000 * 88,
             "2,000,000 tokens at 88 micro-cents each should charge " <>
               "#{2_000_000 * 88}; charged #{charged} — the charge is not following " <>
               "the response"
    end

    # ⬛ ANTI-VACUITY: a DIFFERENT usage must produce a DIFFERENT charge. Without
    # this, a hardcoded constant would satisfy the case above.
    test "a smaller usage is charged proportionally less" do
      body =
        Jason.encode!(%{
          "choices" => [%{"message" => %{"content" => "0.5"}}],
          "usage" => %{"total_tokens" => 500_000}
        })

      assert {:ok, "0.5"} = TogetherClient.parse_success_response(body)

      assert Spend.spent(:together, :daily) == 500_000 * 88
    end

    # ⛔ THE CASE THE OLD UNIT COULD NOT EXPRESS AT ALL. A 400-token completion
    # costs 35,200 micro-cents — about a third of a cent. In cents it rounded up
    # to 1, which is ~28× the real price, and that happened on every ordinary
    # call. The exact figure is the whole point of the change.
    test "an ordinary small completion is charged a fraction of a cent" do
      body =
        Jason.encode!(%{
          "choices" => [%{"message" => %{"content" => "0.7"}}],
          "usage" => %{"total_tokens" => 400}
        })

      assert {:ok, "0.7"} = TogetherClient.parse_success_response(body)

      charged = Spend.spent(:together, :daily)

      assert charged == 400 * 88

      assert charged < 100_000,
             "a 400-token call was charged a whole cent or more (#{charged} " <>
               "micro-cents), which is the rounding this unit exists to remove"
    end

    # ⚖️ A response whose usage block we cannot read still cost something, and
    # recording nothing would make it free. One token's worth is the smallest
    # honest non-zero entry — it says "this happened" without inventing a size.
    test "a response with no usage block is charged one token's worth" do
      body = Jason.encode!(%{"choices" => [%{"message" => %{"content" => "0.3"}}]})

      assert {:ok, "0.3"} = TogetherClient.parse_success_response(body)

      assert Spend.spent(:together, :daily) == 88,
             "a completion with an unreadable usage block was free, or was charged a " <>
               "size nobody measured"
    end
  end
end
