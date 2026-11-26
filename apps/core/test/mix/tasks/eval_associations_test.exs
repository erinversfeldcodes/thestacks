defmodule Mix.Tasks.Eval.AssociationsTest do
  @moduledoc """
      That the association eval measures something, and that its corpus is honest.

      ⛔ THE CORPUS IS THE ARTEFACT MOST LIKELY TO ROT, and it rots silently: a
      fixture that stops reproducing what it was built to reproduce still
      scores, and the eval still passes. The first block here asserts the
      corpus's own properties — the labels, the strata, the truncated fixture
      actually being truncated — rather than trusting them.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Eval.Associations
  alias Stacks.AI.Structured

  setup do
    {:ok, corpus: Associations.load_corpus()}
  end

  describe "the corpus itself" do
    test "it is at least thirty posts", %{corpus: corpus} do
      assert length(corpus) >= 30,
             "the corpus holds #{length(corpus)} items; a smaller set cannot cover the " <>
               "failure space this pass actually has"
    end

    test "every item carries the fields the eval reads", %{corpus: corpus} do
      for item <- corpus do
        assert is_binary(item.name) and item.name != ""
        assert is_atom(item.stratum)
        assert is_binary(item.body) and item.body != ""
        assert is_list(item.candidates)
        assert is_binary(item.response)

        assert is_binary(item.notes) and item.notes != "",
               "#{item.name} has no notes — an item nobody can justify is an item " <>
                 "nobody will dare delete when it becomes wrong"
      end
    end

    # ⚖️ `:unreadable` IS A FIRST-CLASS EXPECTED OUTCOME, not an absence of one.
    # Writing those items as `[]` was a real labelling error on this corpus's
    # first run: "the model said nothing we could read" and "the model found no
    # books" are different facts that want different fixes, and an expectation
    # that cannot tell them apart scores the wrong thing as right.
    test "an expectation is either a list of ids or :unreadable", %{corpus: corpus} do
      for item <- corpus do
        assert is_list(item.expect) or item.expect == :unreadable,
               "#{item.name} expects #{inspect(item.expect)}"
      end
    end

    # ⚖️ THE HALLUCINATION STRATUM IS THE EXCEPTION, DELIBERATELY. This guard
    # used to require every expected id to be a candidate — which was only true
    # while the eval filtered to the candidate list in its own code, a second
    # implementation of a rule that lives in `Blog.associate_book/3`'s foreign
    # key. The decoder reports what the model said, invented ids included; the
    # refusal is the worker's and is tested there.
    test "only the hallucination stratum expects an id outside its candidates",
         %{corpus: corpus} do
      offenders =
        for item <- corpus,
            is_list(item.expect),
            item.stratum != :hallucination,
            id <- item.expect,
            id not in item.candidates,
            do: {item.name, id}

      assert offenders == [],
             "these non-hallucination items expect ids that are not candidates, which " <>
               "means their label is describing a filter nothing applies: " <>
               inspect(offenders)
    end

    test "the strata cover more than the happy path", %{corpus: corpus} do
      strata = corpus |> Enum.map(& &1.stratum) |> Enum.uniq() |> Enum.sort()

      for required <- [:broken, :empty, :fence, :hallucination, :happy] do
        assert required in strata, "the corpus lost its #{required} stratum"
      end
    end

    # ⛔ THE FIXTURE THAT CAN LIE MOST QUIETLY. `truncated_mid_object`
    # reproduces the production defect — a 500-character cap cutting the JSON
    # mid-object — and my first attempt at it was 404 characters long, so the
    # "truncation" was a no-op and the item asserted the opposite of what its
    # name claimed. The eval caught it; this case is what keeps it caught.
    test "the truncated fixture is actually truncated", %{corpus: corpus} do
      item = Enum.find(corpus, &(&1.name == "truncated_mid_object"))

      assert item, "the truncated fixture is gone"
      # ⚖️ `<=`, because the PROPERTY is "cut mid-object" and 500 is a historical
      # detail — the cap that produced it. A 480-character cut mid-object
      # reproduces the defect and a 500-character cut with a closed fence does
      # not, so pinning the exact number is brittle for no return.
      assert String.length(item.response) <= 500,
             "the fixture is longer than the cap that produced it, so it is not what " <>
               "the worker received"

      refute String.ends_with?(String.trim(item.response), "```"),
             "the fixture's fence is closed, so it was not cut mid-object"

      # ⛔ `Structured.decode/1`, NOT `Jason.decode/1`. The plain decoder fails on
      # the first character of EVERY fenced item — that is why this module
      # exists — so this assertion passed for a flawless response and its
      # message ("the fixture parses, so it no longer reproduces the defect")
      # claimed a guarantee it did not give. Proven: `Jason.decode` returns
      # `:error` for `one_book_fenced`, which is a perfect fixture.
      assert {:error, _} = Structured.decode(item.response),
             "the fixture decodes, so it no longer reproduces the defect it is named for"
    end
  end

  describe "what the eval makes of a response" do
    test "a fenced array yields its book ids, in order" do
      raw =
        "```json\n" <>
          ~s([{"book_id": "bbb", "confidence": 0.9, "reasoning": "x"},) <>
          ~s({"book_id": "aaa", "confidence": 0.8, "reasoning": "y"}]) <> "\n```"

      # ⚖️ Order preserved, not sorted: the model's order is information, and
      # sorting here would hide a decoder that reordered.
      assert Associations.associate(raw) == ["bbb", "aaa"]
    end

    # ⛔ THESE TWO USED TO ASSERT RULES THE EVAL HAD COPIED FROM THE WORKER —
    # dropping an id outside the candidate list, and de-duplicating a repeat.
    # Both are the database's job (`foreign_key_constraint(:book_id)` and a
    # unique index), and the copy diverged: nothing de-duplicated in
    # production, so the corpus certified a behaviour the system did not have
    # and a reader really did get two identical associations. Now the decoder's
    # own behaviour is asserted, and the rules are tested where they live.
    test "an id the catalogue has never heard of is still reported" do
      raw = ~s([{"book_id": "real"}, {"book_id": "invented"}])

      assert Associations.associate(raw) == ["real", "invented"]
    end

    test "the same id twice is reported twice" do
      raw = ~s([{"book_id": "same", "confidence": 0.9}, {"book_id": "same", "confidence": 0.4}])

      assert Associations.associate(raw) == ["same", "same"]
    end

    # ⚖️ An unreadable response is NOT an empty one, and the eval must not
    # collapse them — that was a labelling error on the corpus's first run, and
    # it would hide a decoder that had stopped working behind a set of posts
    # with no books.
    test "an unreadable response is distinguished from an empty answer" do
      assert Associations.associate("I could not find any books.") == :unreadable
      assert Associations.associate("[]") == []
    end
  end

  describe "the stratum filter" do
    test "it selects only that stratum", %{corpus: corpus} do
      filtered = Associations.only_stratum(corpus, "fence")

      assert filtered != []
      assert Enum.all?(filtered, &(&1.stratum == :fence))
      assert length(filtered) < length(corpus)
    end

    # ⛔ A misspelled stratum would otherwise score 0/0 and report no
    # regression — a gate passing because it tested nothing.
    test "a stratum nobody has refuses rather than scoring nothing", %{corpus: corpus} do
      error = assert_raise Mix.Error, fn -> Associations.only_stratum(corpus, "fences") end

      assert error.message =~ "no corpus item has stratum"
      assert error.message =~ "fence"
    end
  end

  describe "the floor" do
    # ⚖️ THIS IS THE REAL GATE, AND THE CI STEP IS THE END-TO-END CHECK.
    #
    # A reviewer noted the two duplicate each other, and they do — but not
    # identically: this case names the failing items, which a task exit code
    # cannot, and the CI step proves the task itself still runs. What was worth
    # removing was the cost, not the step: the task now runs under `app.config`
    # rather than `app.start`, so it no longer boots nine circuit breakers and
    # opens a database connection to decode strings from a file.
    test "a corpus that scores perfectly passes", %{corpus: corpus} do
      results = Enum.map(corpus, &Associations.score_item/1)

      assert Enum.all?(results, & &1.passed),
             "these items fail: " <>
               inspect(results |> Enum.reject(& &1.passed) |> Enum.map(& &1.name))
    end

    # ⬛ ANTI-VACUITY FOR THE FLOOR: it must actually refuse. A gate whose
    # failure path has never run is a gate nobody has tested.
    test "one wrong item fails the gate" do
      results = [
        %{name: "ok", stratum: :happy, expected: [], got: [], passed: true, notes: "n"},
        %{name: "bad", stratum: :happy, expected: ["a"], got: [], passed: false, notes: "n"}
      ]

      assert_raise Mix.Error, fn -> Associations.gate(results) end
    end
  end
end
