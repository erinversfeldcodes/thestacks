defmodule Stacks.AI.StructuredTest do
  @moduledoc """
      Whether the decoder survives what the model actually sends.

      ⛔ THE FIRST describe BLOCK IS NOT ABOUT THE DECODER AT ALL. It asserts
      that the fixtures still have the properties the live captures were
      measured to have — fenced, 744–782 characters, rejected by `Jason.decode/1`,
      and still rejected after a 500-character cut. Without that, every case
      below could pass against fixtures that had drifted into something the
      model never sends, and the suite would be testing a story.
  """
  use ExUnit.Case, async: true

  alias Stacks.AI.Structured
  alias Stacks.Test.Fixtures.LlmAssociationResponses, as: Responses

  describe "the fixtures still match the measured captures" do
    test "every well-formed response is fenced" do
      for raw <- Responses.all_fenced() do
        assert raw |> String.trim() |> String.starts_with?("```"),
               "a fixture lost its fence, so the decoder's whole subject is gone"
      end
    end

    test "the three-association response sits in the captured length band" do
      length = String.length(Responses.fenced_three())

      assert length >= 744 and length <= 782,
             "the captures measured 744-782 characters (285/276/283 completion tokens); " <>
               "this fixture is #{length}, so it no longer reproduces what was measured"
    end

    # ⛔ THE DEFECT, RESTATED AS AN ASSERTION. This is what the worker did to
    # every response before this work: `Jason.decode/1` on the raw text.
    test "Jason.decode fails on all of them, which is the bug" do
      for raw <- Responses.all_fenced() do
        assert {:error, _} = Jason.decode(raw),
               "a fixture became decodable by the old path, so it no longer " <>
                 "represents the failure this module exists to fix"
      end
    end

    # ⚠️ The chain was dead TWICE at one hop, and this is the second death: even
    # if the fence were handled, the 500-character cap cut the JSON mid-object.
    test "a 500-character cut is still broken, independently of the fence" do
      truncated = Responses.truncated_at_500()

      assert String.length(truncated) == 500
      assert {:error, _} = Jason.decode(truncated)

      assert {:error, {:unparseable, _}} = Structured.decode(truncated),
             "a truncated response must fail as unparseable — this is the shape the " <>
               "worker received for every completion before the cap was removed"
    end
  end

  describe "decoding what the model sends" do
    test "a fenced array of associations decodes" do
      assert {:ok, associations} = Structured.decode(Responses.fenced_three())
      assert length(associations) == 3

      assert Enum.map(associations, & &1.book_id) == [
               "9d1f0c3a-5e4b-4a21-8f07-2c6b9ad3e114",
               "3b7e2d14-9a6c-4f58-b013-7e8a1c45d920",
               "c05a8e62-1d3f-4b97-a2e4-6f91b08d7c33"
             ]

      assert Enum.map(associations, & &1.confidence) == [0.92, 0.71, 0.48]
    end

    # ⚖️ The opening fence varies — ```json, ```JSON, bare ``` — and pinning one
    # spelling would re-create the defect one variant along.
    test "a bare ``` fence decodes too" do
      assert {:ok, [first, second]} = Structured.decode(Responses.fenced_two_bare_fence())
      assert first.book_id == "7f2c9b31-8e05-4d6a-9c14-3a7e5d2b0f88"
      assert second.confidence == 0.55
    end

    test "a fenced empty array is an answer, not a failure" do
      assert {:ok, []} = Structured.decode(Responses.fenced_empty())
    end

    # ⛔ THE SHAPE THE SCHEMA ACTUALLY ASKS FOR. `association_schema/0` wraps the
    # array in an object, because an array root is undocumented on this
    # provider — so a model that OBEYS the schema sends this, and refusing it
    # would make the schema's own success look like a parse failure.
    test "the wrapped object the schema asks for decodes" do
      raw = ~s({"associations": [{"book_id": "abc", "confidence": 0.7, "reasoning": "named"}]})

      assert {:ok, [%{book_id: "abc", confidence: 0.7}]} = Structured.decode(raw)
    end

    test "and wrapped inside a fence, which is both at once" do
      raw = "```json\n{\"associations\": [{\"book_id\": \"x\"}]}\n```"

      assert {:ok, [%{book_id: "x"}]} = Structured.decode(raw)
    end

    # ⬛ ANTI-VACUITY FOR THE FENCE HANDLING: unfenced JSON must still work. If
    # `strip_fence/1` were written to require a fence, every case above would
    # pass while the decoder broke on the response the schema is meant to
    # produce.
    test "an unfenced array — what response_format should yield — decodes" do
      raw = ~s([{"book_id": "abc", "confidence": 0.5, "reasoning": "named twice"}])

      assert {:ok, [%{book_id: "abc", confidence: 0.5}]} = Structured.decode(raw)
    end
  end

  describe "when it cannot be read" do
    # ⛔ THE RAW TEXT TRAVELS WITH THE ERROR. The old path logged a warning and
    # discarded it, so the question anyone asks next — what did it actually
    # say? — had no answer.
    test "an unparseable response carries its own text" do
      raw = "I looked at the post and I don't think any of these books are discussed."

      assert {:error, {:unparseable, ^raw}} = Structured.decode(raw)
    end

    # ⚖️ A DIFFERENT FAILURE, DELIBERATELY NAMED. Valid JSON that is not a list
    # means the model understood the format and not the task. Collapsing it into
    # `:unparseable` would hide which is happening, and the two want different
    # fixes — a prompt change versus a parsing change.
    # ⚠️ STILL unexpected_shape, even though it has an "associations" key — the
    # value is not a list, so there is nothing to read. The wrapped-object case
    # above accepts the shape; this one makes sure acceptance is about the LIST
    # and not about the key's presence.
    test "valid JSON of the wrong shape is unexpected_shape, not unparseable" do
      raw = Responses.object_not_array()

      assert {:error, {:unexpected_shape, ^raw}} = Structured.decode(raw)
    end

    test "an associations key holding something other than a list is refused" do
      raw = ~s({"associations": "none that I could find"})

      assert {:error, {:unexpected_shape, _}} = Structured.decode(raw)
    end

    # ⚠️ One bad row must not cost the good ones. The old behaviour was
    # all-or-nothing in the other direction; losing four associations to one
    # malformed entry is the same defect wearing a different face.
    test "a malformed entry is dropped, and its neighbours survive" do
      raw = ~s([{"book_id": "keep", "confidence": 0.9}, {"no_book_id": true}])

      assert {:ok, [%{book_id: "keep"}]} = Structured.decode(raw)
    end

    # ⚖️ NULL, not merely absent. `association_schema/0` lists every key as
    # required with the optional ones nullable — the shape that is valid under
    # the strictest documented reading of strict mode — so a model obeying it
    # sends `null` rather than omitting the key, and both must land the same.
    test "a null confidence is handled like a missing one" do
      raw = ~s([{"book_id": "keep", "confidence": null, "reasoning": null}])

      assert {:ok, [%{book_id: "keep", confidence: 0.0, reasoning: ""}]} = Structured.decode(raw)
    end

    test "a missing confidence does not discard the association" do
      raw = ~s([{"book_id": "keep", "reasoning": "named in the second paragraph"}])

      assert {:ok, [%{book_id: "keep", confidence: 0.0, reasoning: reasoning}]} =
               Structured.decode(raw)

      assert reasoning == "named in the second paragraph"
    end
  end
end
