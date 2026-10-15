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

  use ExUnit.Case, async: false

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
end
