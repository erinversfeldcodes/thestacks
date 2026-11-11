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

      assert {:ok, [%{book_id: "keep", confidence: +0.0, reasoning: ""}]} = Structured.decode(raw)
    end

    test "a missing confidence does not discard the association" do
      raw = ~s([{"book_id": "keep", "reasoning": "named in the second paragraph"}])

      assert {:ok, [%{book_id: "keep", confidence: +0.0, reasoning: reasoning}]} =
               Structured.decode(raw)

      assert reasoning == "named in the second paragraph"
    end
  end

  describe "the fence, at its edges" do
    # ⛔ THESE FIVE CASES EXIST BECAUSE MY OWN FIX BROKE TWO OF THEM.
    #
    # Widening the fence regex from anchored `\A…\z` to unanchored — so that
    # prose around the fence stops defeating the strip — silently broke every
    # response whose `reasoning` quotes a code block. Measured at the time:
    # both a fenced and an unfenced response carrying ``` inside a string went
    # from parsing to `:unparseable`. A model quoting code in its explanation is
    # not exotic, and no test in this file saw it.
    #
    # ⚖️ The fix is the OPENING ANCHOR, and that is all of it. A first attempt
    # also carried a runtime guard that re-parsed and fell back — removed,
    # because it probed green (the anchor makes it unreachable for anything that
    # could parse) and because a regex trying to be exactly right plus a guard
    # forgiving it for being wrong is two mechanisms for one job: the guard made
    # the pattern's quality unobservable, which is how the first fix went
    # unnoticed.
    #
    # ⬛ The class it defended — a fence change breaking a response that already
    # decoded — has two confirmed instances, both from one day's edits to this
    # one line. So it is defended by an ASSERTION instead, below: insurance
    # never fires during the window you measure it in, which is exactly why
    # "it probes green" is the wrong instrument for it.

    test "prose before the fence does not defeat it" do
      raw = "Here are the associations I found:\n\n```json\n" <> ~s([{"book_id": "a"}]) <> "\n```"

      assert {:ok, [%{book_id: "a"}]} = Structured.decode(raw)
    end

    test "prose after the fence does not defeat it" do
      raw =
        "```json\n" <> ~s([{"book_id": "b"}]) <> "\n```\n\nLet me know if you'd like more."

      assert {:ok, [%{book_id: "b"}]} = Structured.decode(raw)
    end

    # ⛔ THE REGRESSION, PINNED. An unfenced response whose reasoning quotes a
    # code block must not be touched by the fence logic at all.
    test "backticks inside an unfenced response's reasoning are left alone" do
      raw = ~s([{"book_id": "c", "reasoning": "the post quotes ```code``` inline"}])

      assert {:ok, [%{book_id: "c", reasoning: reasoning}]} = Structured.decode(raw)
      assert reasoning =~ "```code```"
    end

    # ⛔ AND THE SAME THING INSIDE A REAL FENCE, which the non-greedy version
    # cut short at the inner backticks.
    test "backticks inside a fenced response's reasoning survive" do
      raw = "```json\n" <> ~s([{"book_id": "d", "reasoning": "uses ``` thrice"}]) <> "\n```"

      assert {:ok, [%{book_id: "d", reasoning: "uses ``` thrice"}]} = Structured.decode(raw)
    end

    # ⚖️ TWO FENCES IS TWO ANSWERS, AND IT FAILS LOUDLY RATHER THAN PICKING
    # ONE. Silently taking the first would be a guess presented as a result;
    # `:unparseable` sends the author the honest message and puts the raw text
    # in the call log for whoever looks. Consistent with this module's position
    # throughout: unreadable is not empty.
    test "two fenced blocks are refused rather than guessed between" do
      raw =
        "```json\n" <>
          ~s([{"book_id": "first"}]) <>
          "\n```\n\nand also:\n\n```json\n" <> ~s([{"book_id": "second"}]) <> "\n```"

      assert {:error, {:unparseable, _}} = Structured.decode(raw)
    end

    test "an unterminated fence is unparseable" do
      assert {:error, {:unparseable, _}} =
               Structured.decode("```json\n" <> ~s([{"book_id": "e"}]))
    end
  end

  describe "the shapes a transport produces, not a model" do
    # ⛔ CRLF BROKE, AND IT WOULD HAVE ARRIVED AS A BLANKET FAILURE.
    #
    # Narrowing the fence regex's whitespace class from `\s` to `[ \t]` removed
    # `\r` — so every fenced response over a transport using CRLF became
    # `:unparseable` at once, rather than occasionally. Line endings are not a
    # property of the model, which is what makes this worse than a model
    # variant: no corpus item would have caught it.
    test "a fenced response with CRLF line endings decodes" do
      raw = "```json\r\n" <> ~s([{"book_id": "a", "confidence": 0.9}]) <> "\r\n```"

      assert {:ok, [%{book_id: "a"}]} = Structured.decode(raw)
    end

    # ⛔ A1, A2 AND A7 — THE REALISTIC FAMILY, AND THE THREE I BROKE BY
    # RELAXING THE ANCHORS.
    #
    # Making the inner newlines optional and dropping the trailing anchor did
    # not reopen the string-match hole (the opening anchor still closes that),
    # but it changed WHICH fence the match selects: the greedy capture ran to
    # the last ``` anywhere, and a line merely beginning ` ```json ` swallowed
    # the real fence after it. All three are a model that answers and then says
    # one more thing — the same family as the backticks-in-reasoning bug.
    test "prose containing backticks AFTER the fence does not confuse it" do
      raw =
        "```json\n" <> ~s([{"book_id": "a"}]) <> "\n```\n\nBy the way, use ``` to fence code."

      assert {:ok, [%{book_id: "a"}]} = Structured.decode(raw)
    end

    test "a line that merely begins with a fence does not swallow the real one" do
      raw =
        "I will use:\n```json blocks for this\n\nand the answer:\n\n```json\n" <>
          ~s([{"book_id": "b"}]) <> "\n```"

      assert {:ok, [%{book_id: "b"}]} = Structured.decode(raw)
    end

    test "the same, in the wrapped-object shape" do
      raw =
        "```json\n" <>
          ~s({"associations": [{"book_id": "c"}]}) <> "\n```\n\nuse ``` for code."

      assert {:ok, [%{book_id: "c"}]} = Structured.decode(raw)
    end

    # ⚖️ THE PRICE, STATED RATHER THAN INHERITED. These two are refused, and the
    # decision is deliberate: neither has been observed from this provider — the
    # measured captures are all multi-line `\n`-fenced — and neither worked
    # before the relaxation either. Recovering them needs a candidate set with
    # both greedy and non-greedy extractions, because a non-greedy scan alone
    # consumes past the real fence and the genuine block never becomes a
    # candidate. That is measured work, not a regex tweak.
    #
    # ⬛ Asserted rather than left untested, so the next person sees the trade
    # instead of discovering it. If these start arriving, this is the case to
    # delete — and the three above are what it must not cost.
    test "a single-line fence is refused, by choice" do
      raw = "```json " <> ~s([{"book_id": "d"}]) <> " ```"

      assert {:error, {:unparseable, _}} = Structured.decode(raw)
    end

    test "prose on the closing fence's own line is refused, by the same choice" do
      raw = "```json\n" <> ~s([{"book_id": "e"}]) <> "\n``` done."

      assert {:error, {:unparseable, _}} = Structured.decode(raw)
    end
  end

  describe "the invariant the removed guard used to carry" do
    # ⛔ THE ASSERTION THAT REPLACES THE RUNTIME FALLBACK, AND THE REASON IT IS
    # AN ASSERTION.
    #
    # A guard that re-parsed and fell back would have caught a future fence
    # pattern breaking a response that already decoded — the class that has
    # happened twice, both times in one day, on the most-churned line in this
    # module. But insurance never fires during the window you measure, so
    # "it probes green" could not distinguish it from dead code, and keeping it
    # made the regex's quality unobservable.
    #
    # ⚖️ So the invariant is stated instead of enforced: **anything plain JSON
    # accepts, this decoder must also accept.** That reds the moment a regex
    # change breaks it, keeps one mechanism, and leaves the pattern observable.
    test "every response plain JSON can read, this decoder can read" do
      corpus =
        Path.join(Application.app_dir(:core), "priv/eval/association_corpus.exs")
        |> Code.eval_file()
        |> elem(0)

      plain = Enum.filter(corpus, &match?({:ok, _}, Jason.decode(&1.response)))

      assert plain != [],
             "no corpus response is plain JSON, so this case asserts nothing — the " <>
               "invariant needs at least one unfenced item to hold over"

      for item <- plain do
        assert match?({:ok, _}, Structured.decode(item.response)) or
                 match?({:error, {:unexpected_shape, _}}, Structured.decode(item.response)),
               "#{item.name} is readable by Jason.decode and this decoder reports " <>
                 "#{inspect(Structured.decode(item.response))} — a fence change has " <>
                 "broken a response that already worked"
      end
    end

    # ⬛ AND THE TWO SHAPES THAT ARE NOT IN THE CORPUS, because backticks inside
    # a string are the exact input the broken regex mangled.
    test "backticks inside a string survive, fenced or not" do
      unfenced = ~s([{"book_id": "d", "reasoning": "quotes ```code``` inline"}])
      fenced = "```json\n" <> ~s([{"book_id": "e", "reasoning": "uses ``` thrice"}]) <> "\n```"

      assert {:ok, [%{book_id: "d"}]} = Structured.decode(unfenced)
      assert {:ok, [%{book_id: "e"}]} = Structured.decode(fenced)
    end
  end

  describe "the confidence a model reports" do
    # ⛔ A HALLUCINATED 1.4 SORTED ABOVE A CERTAIN 1.0 ON THE AUTHOR'S PAGE.
    #
    # Nothing guarded the range — no `validate_number`, no CHECK constraint, a
    # plain `:float` column — and `Blog.list_associations/1` orders by
    # `confidence desc`. So the least trustworthy answer was presented first,
    # *because* it was the most confident.
    #
    # ⚠️ Found by a reviewer noting that the association corpus's eight
    # confidence items **could not fail on a confidence value**: replacing every
    # one with `"banana"` left 8/8 passing, and so did deleting the key. Three
    # of those items' notes claimed to make clamping-versus-dropping visible and
    # nothing scored it. These cases are what makes the number observable.
    test "a confidence above one is clamped, not persisted as given" do
      raw = ~s([{"book_id": "a", "confidence": 1.4, "reasoning": "x"}])

      assert {:ok, [%{confidence: 1.0}]} = Structured.decode(raw)
    end

    test "a negative confidence is clamped to zero" do
      raw = ~s([{"book_id": "b", "confidence": -0.2, "reasoning": "x"}])

      assert {:ok, [%{confidence: +0.0}]} = Structured.decode(raw)
    end

    # ⚖️ CLAMPED, NOT DROPPED. The association is still information — the model
    # named a book the post discusses — and only the number is out of range, so
    # discarding the row would throw away the useful half to punish the useless
    # one.
    test "an out-of-range confidence keeps its association" do
      raw = ~s([{"book_id": "c", "confidence": 99.0, "reasoning": "named twice"}])

      assert {:ok, [%{book_id: "c", reasoning: "named twice"}]} = Structured.decode(raw)
    end

    # ⬛ ANTI-VACUITY: an in-range value must pass through untouched, or a
    # clamp that returned a constant would satisfy every case above.
    test "an in-range confidence is unchanged" do
      raw = ~s([{"book_id": "d", "confidence": 0.37}, {"book_id": "e", "confidence": 1.0}])

      assert {:ok, [%{confidence: 0.37}, %{confidence: 1.0}]} = Structured.decode(raw)
    end

    # ⚠️ And a string confidence is parsed THEN clamped — `as_float/1` has three
    # branches and the clamp has to be on all of them.
    test "a string confidence out of range is also clamped" do
      raw = ~s([{"book_id": "f", "confidence": "2.5"}])

      assert {:ok, [%{confidence: 1.0}]} = Structured.decode(raw)
    end
  end
end
