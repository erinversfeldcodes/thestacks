defmodule Mix.Tasks.Eval.VisionTest do
  @moduledoc """
      The eval gate's own behaviour, which nothing tested until now.

      ⛔ THIS TASK IS A DEPLOY GATE AND HAD NO TEST. It decides whether a vision
      change ships, and the three verdicts it can reach — scored a regression,
      scored clean, could not score — were asserted by nobody. Two of them were
      wrong:

        * **"no baseline" exited 0.** A gate with nothing to compare against
          reported success, so every stack that had never recorded a baseline
          passed unconditionally and "nothing is being gated" read as "nothing
          is wrong".
        * **The baseline carried no model identity.** A new architecture would
          have inherited the VLM's number, so the first candidate for the vision
          redesign would have been gated against a baseline describing a
          different system — cleared or failed for a reason that had nothing to
          do with it.

      ⚖️ Asserted on the decision functions rather than by running the task:
      `run/1` calls a live vision service, and a test that needs the network to
      say whether a gate is correct is a test nobody runs on a PR.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Eval.Vision

  @identity %{model: "qwen2-vl-7b", modal_app: "https://vision.example.test"}

  defp recorded(attrs) do
    Jason.encode!(Map.merge(%{"passed" => 6, "total" => 6}, attrs))
  end

  describe "a baseline belongs to a model" do
    test "the same identity compares" do
      body = recorded(%{"model" => "qwen2-vl-7b", "modal_app" => "https://vision.example.test"})

      assert {:ok, 6} = Vision.baseline_for(body, @identity)
    end

    # ⛔ THE CASE THE VISION REDESIGN TURNS ON. A candidate architecture must not
    # be measured against the baseline of the model it replaces.
    test "a different model is a mismatch, not a comparison" do
      body =
        recorded(%{"model" => "some-other-vlm", "modal_app" => "https://vision.example.test"})

      assert {:mismatch, "some-other-vlm"} = Vision.baseline_for(body, @identity),
             "a baseline recorded for another model must not be borrowed — a new " <>
               "architecture earns its own"
    end

    # ⚠️ Same model, different deployment. The service URL is part of the
    # identity because the same weights behind a different app are not
    # self-evidently the same system, and assuming they are is how a baseline
    # silently spans two.
    test "the same model on a different app is also a mismatch" do
      body = recorded(%{"model" => "qwen2-vl-7b", "modal_app" => "https://other.example.test"})

      assert {:mismatch, _} = Vision.baseline_for(body, @identity)
    end

    # ⬛ ANTI-VACUITY: if `baseline_for/2` returned `{:mismatch, _}` for
    # everything, the two cases above would pass and the gate would never
    # compare anything again. The matching case above is what excludes that —
    # and this one excludes the opposite, a parser that accepts anything.
    test "a baseline with no model recorded at all is a mismatch" do
      body = recorded(%{})

      assert {:mismatch, nil} = Vision.baseline_for(body, @identity),
             "a baseline predating model identity cannot be assumed to describe this " <>
               "model — it is exactly the inheritance this change prevents"
    end

    test "an unparseable baseline is distinguishable from an absent one" do
      assert :unreadable = Vision.baseline_for("{not json", @identity),
             "a corrupt baseline file must not read as 'no baseline yet' — one is a " <>
               "setup state, the other is a fault"
    end
  end

  describe "the identity it scores under" do
    test "is read from the same config the service call uses" do
      identity = Vision.model_identity()

      assert Map.has_key?(identity, :model)
      assert Map.has_key?(identity, :modal_app)
    end
  end

  describe "a gate with nothing to compare against" do
    setup do
      # A baseline path the task will not find, so `read_baseline` returns
      # `:absent` — the state every stack is in before the first `--record`.
      previous = Application.get_env(:core, :vision_model)

      Application.put_env(
        :core,
        :vision_model,
        "a-model-with-no-baseline-#{System.unique_integer()}"
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:core, :vision_model, previous),
          else: Application.delete_env(:core, :vision_model)
      end)

      :ok
    end

    # ⚠️ ASSERTS THE EXACT BRANCH, not "something raised". Written first with a
    # loose `NO BASELINE FOR THIS MODEL|NO BASELINE` alternation, it passed
    # against BOTH branches — so a probe restoring the `:absent` branch to
    # `Mix.shell().info` left it green, because this setup actually exercises
    # the MISMATCH path. A test that cannot say which refusal it got is
    # satisfied by the wrong one.
    test "an unrecognised model fails rather than passing" do
      results = [%{ok: true, name: "a", detail: ""}, %{ok: true, name: "b", detail: ""}]

      error =
        assert_raise Mix.Error, fn ->
          Vision.gate(results, false)
        end

      assert error.message =~ "NO BASELINE FOR THIS MODEL",
             "expected the model-mismatch refusal; got: #{error.message}"
    end

    # ⛔ THE HOUSE FAILURE MODE, AND IT NEEDS THE FILE GONE TO REACH IT. This
    # branch used to print a note and exit 0 — a deploy gate reporting success
    # because it had nothing to compare against, so every stack that had never
    # recorded a baseline passed unconditionally.
    test "no baseline file at all fails too" do
      path = Path.join(Application.app_dir(:core), "priv/eval/vision_baseline.json")
      kept = File.read(path)
      File.rm(path)

      on_exit(fn ->
        case kept do
          {:ok, body} -> File.write!(path, body)
          _ -> :ok
        end
      end)

      error =
        assert_raise Mix.Error, fn ->
          Vision.gate([%{ok: true, name: "a", detail: ""}], false)
        end

      assert error.message =~ "NO BASELINE",
             "a gate with no baseline file must refuse; got: #{error.message}"
    end

    # ⚖️ ANTI-VACUITY: `--record` must still work, or the fix above would make
    # the baseline impossible to create and the gate permanently red.
    test "but recording one is still allowed" do
      results = [%{ok: true, name: "a", detail: ""}]

      assert Vision.gate(results, true) != :error
    end
  end

  describe "the three outcomes it can reach" do
    # ⛔ ONLY ONE OF THE THREE IS EVIDENCE ABOUT THE MODEL. A wrong answer is;
    # a call that never completed is not; and a fixture the harness could not
    # read is a fact about the CORPUS. Collapsing the last two into "miss" is
    # how a moved file or a cold service gets reported as a model regression —
    # which this task did once, and the retry comment records.
    test "a wrong answer is scored, and counts against the baseline" do
      results = [%{ok: false, name: "a", detail: "is_book=false"}]

      refute Enum.any?(results, & &1.ok)
      refute Enum.any?(results, &Map.get(&1, :unscored, false))
    end

    # ⚠️ Drives `gate/2` rather than asserting a map shape: the claim is that an
    # unscored case STOPS the gate, not merely that it carries a flag.
    test "an unscored case refuses the verdict instead of failing it" do
      results = [
        %{ok: true, name: "a", detail: ""},
        %{ok: false, name: "b", unscored: true, detail: "call failed"}
      ]

      error = assert_raise Mix.Error, fn -> Vision.gate(results, false) end

      assert error.message =~ "INCOMPLETE",
             "an unscored case must neither prove a regression nor clear the gate; got: " <>
               error.message

      refute error.message =~ "REGRESSION",
             "a case that could not be scored must not be reported as the model getting " <>
               "something wrong — that is the misattribution this class exists to prevent"
    end

    # ⛔ THE CORPUS'S OWN DECAY, which used to read as the model regressing. A
    # fixture that was moved, renamed or never committed scored `ok: false` with
    # no `unscored` flag — so a missing file counted against the baseline and
    # the next person would have gone looking at the model.
    test "a fixture the harness cannot read is unscored, not a miss" do
      scored =
        Vision.score_image(%{
          path: "no/such/fixture-#{System.unique_integer([:positive])}.jpg",
          name: "missing",
          expect_book: true,
          expect_isbn: nil
        })

      assert scored.unscored,
             "an unreadable fixture is a fact about the corpus, not an answer from the " <>
               "model — scoring it as a miss makes corpus decay look like regression"

      assert scored.detail =~ "the corpus, not the model"
    end

    # ⚖️ ANTI-VACUITY: without this, a `gate/2` that raised INCOMPLETE on
    # everything would pass the case above.
    test "a fully scored run reaches a verdict" do
      results = [%{ok: true, name: "a", detail: ""}]

      error = assert_raise Mix.Error, fn -> Vision.gate(results, false) end

      refute error.message =~ "INCOMPLETE",
             "a run with nothing unscored must reach a baseline verdict, not refuse one"
    end
  end
end
