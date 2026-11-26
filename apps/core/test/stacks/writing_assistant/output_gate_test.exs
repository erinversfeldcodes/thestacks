defmodule Stacks.WritingAssistant.OutputGateTest do
  @moduledoc """
      The never-verbatim gate and the faithfulness check, each planted so it can
      fail: lowering the hard-block threshold or dropping the gray-band block
      reds the verbatim tests, and making faithfulness/2 always return :ok reds
      the unfaithful test.
  """
  use ExUnit.Case, async: true

  alias Stacks.WritingAssistant.OutputGate

  defp run_of(n), do: Enum.map_join(1..n, " ", &"tok#{&1}")

  describe "verbatim/3" do
    test "blocks a response that reproduces 50+ contiguous tokens of a chunk" do
      passage = run_of(60)
      response = "here is my answer " <> passage <> " and that is all"

      assert {:block, :verbatim, run} = OutputGate.verbatim(response, [passage])
      assert run >= 50
    end

    test "the owner reading their own text bypasses the gate" do
      passage = run_of(60)
      assert :ok = OutputGate.verbatim(passage, [passage], owner_reading_own: true)
    end

    test "blocks distinctive prose in the gray band (8-50 tokens)" do
      span = "zeta eta theta iota kappa lambda mu nu xi omicron"
      chunk = "before " <> span <> " after"
      response = "prefix " <> span <> " suffix"

      assert {:block, :verbatim, run} = OutputGate.verbatim(response, [chunk])
      assert run in 8..49
    end

    test "allows a bibliographic reference in the gray band" do
      biblio = "isbn 9780141439518 by penguin classics in a later edition"
      chunk = "published " <> biblio <> " worldwide"
      response = "the source is " <> biblio <> " which is canonical"

      assert :ok = OutputGate.verbatim(response, [chunk])
    end

    test "allows a paraphrase with only short incidental overlap" do
      chunk = "the protagonist wandered the misty moors at dawn feeling the weight of memory"
      response = "at first light the main character crossed foggy hills burdened by recollection"

      assert :ok = OutputGate.verbatim(response, [chunk])
    end
  end

  describe "faithfulness/2" do
    test "flags a sentence whose claims appear in no retrieved span" do
      spans = ["the moors were cold and misty at dawn"]
      response = "A dragon breathed fire across the castle towers."

      assert {:unfaithful, [sentence]} = OutputGate.faithfulness(response, spans)
      assert sentence =~ "dragon"
    end

    test "passes a response grounded in the spans" do
      spans = ["the moors were cold and misty at dawn"]
      response = "The moors were misty. It was cold at dawn."

      assert :ok = OutputGate.faithfulness(response, spans)
    end
  end
end
