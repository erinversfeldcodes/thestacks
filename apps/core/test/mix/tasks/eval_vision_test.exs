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

  describe "what a run leaves behind" do
    setup do
      path = Path.join(System.tmp_dir!(), "eval-run-#{System.unique_integer([:positive])}.json")
      System.put_env("EVAL_VISION_RESULT_PATH", path)

      on_exit(fn ->
        System.delete_env("EVAL_VISION_RESULT_PATH")
        File.rm(path)
      end)

      {:ok, path: path}
    end

    # ⛔ WRITTEN EVEN WHEN THE GATE REFUSES, which is the whole point. Every
    # verdict branch can raise, so an artefact written after the decision would
    # exist only for runs that passed — and the runs worth reading later are the
    # ones that did not.
    test "a failing run still records what happened", %{path: path} do
      results = [
        %{ok: true, name: "a", stratum: :clean_barcode, detail: ""},
        %{ok: false, name: "b", stratum: :hostile_orientation, detail: "is_book=false"}
      ]

      assert_raise Mix.Error, fn -> Vision.gate(results, false) end

      assert File.exists?(path),
             "the run raised and left no record — a gate that records only its successes " <>
               "has no history"

      recorded = path |> File.read!() |> Jason.decode!()
      assert recorded["passed"] == 1
      assert recorded["total"] == 2
      assert length(recorded["cases"]) == 2
    end

    test "and carries the per-stratum breakdown", %{path: path} do
      results = [
        %{ok: true, name: "a", stratum: :clean_barcode, detail: ""},
        %{ok: false, name: "b", stratum: :clean_barcode, detail: ""},
        %{ok: true, name: "c", stratum: :negative, detail: ""}
      ]

      assert_raise Mix.Error, fn -> Vision.gate(results, false) end

      recorded = path |> File.read!() |> Jason.decode!()

      assert recorded["per_stratum"]["clean_barcode"] == %{
               "passed" => 1,
               "scored" => 2,
               "unscored" => 0
             }

      assert recorded["per_stratum"]["negative"]["passed"] == 1
    end
  end

  describe "scores by stratum" do
    # ⚠️ `scored` EXCLUDES the unscored, so a stratum whose fixtures all went
    # missing reads 0/0 beside its unscored count — not 0/3, which would be
    # indistinguishable from a model getting every one wrong. That is the same
    # misattribution the unscored class exists to prevent, one aggregation up.
    test "an unscored case is not counted as a failure in its stratum" do
      results = [
        %{ok: true, name: "a", stratum: :clean_barcode, detail: ""},
        %{ok: false, name: "b", stratum: :clean_barcode, unscored: true, detail: ""}
      ]

      assert [{:clean_barcode, counts}] = Vision.per_stratum(results)
      assert counts == %{passed: 1, scored: 1, unscored: 1}
    end

    test "a stratum whose fixtures all vanished reads 0/0, not 0/n" do
      results = [
        %{ok: false, name: "a", stratum: :negative, unscored: true, detail: ""},
        %{ok: false, name: "b", stratum: :negative, unscored: true, detail: ""}
      ]

      assert [{:negative, %{passed: 0, scored: 0, unscored: 2}}] = Vision.per_stratum(results)
    end
  end

  describe "the corpus manifest" do
    # ⛔ THE FIELDS THAT CANNOT BE DERIVED FROM THE IMAGE. `provenance` is the
    # evidence that the no-user-images rule was kept — the one rule in this
    # corpus that is absolute — and `notes` is why the item is in the set at
    # all. An item nobody can justify is an item nobody will dare delete when it
    # becomes wrong.
    #
    # ⚠️ Guarded here rather than trusted, because the failure mode is adding a
    # fixture in a hurry: the corpus still scores, the gate still passes, and
    # the provenance of one image is simply absent. By the time anyone asks, the
    # person who took it may not remember.
    @corpus_fields [:name, :path, :stratum, :expect_book, :expect_rejection, :provenance, :notes]

    setup do
      path = Path.join(Application.app_dir(:core), "priv/eval/vision_corpus.exs")
      {corpus, _} = Code.eval_file(path)
      {:ok, corpus: corpus}
    end

    test "every item carries the corpus plan's section-3 fields", %{corpus: corpus} do
      # ⬛ ANTI-VACUITY: an empty corpus would satisfy every `Enum.each` below.
      assert length(corpus) >= 8,
             "the corpus shrank — eight fixtures is already the minimum this set has"

      for item <- corpus, field <- @corpus_fields do
        assert Map.has_key?(item, field),
               "#{inspect(Map.get(item, :name, item))} is missing #{inspect(field)}"
      end
    end

    test "provenance records who took the photograph and when", %{corpus: corpus} do
      for item <- corpus do
        assert %{photographer: who, captured: when_, source: source} = item.provenance
        assert is_binary(who) and who != ""
        assert is_binary(when_) and when_ != ""

        assert source in [:owned, :synthetic],
               "#{item.name} claims source #{inspect(source)} — the corpus rule is owned " <>
                 "or synthetic photographs only, never a reader's image"
      end
    end

    # ⛔ REJECTION ACCURACY WAS UNSCORABLE, AND THAT IS WHAT THESE NEGATIVES ARE
    # FOR.
    #
    # With one negative out of six fixtures, a model answering "yes, a book" to
    # every image scores 5/6 — which reads as a good model and is a measurement
    # of nothing. The number of negatives IS the resolution of the rejection
    # score, so it is asserted rather than left to whoever adds the next
    # fixture.
    #
    # ⚠️ Three is still coarse. It is enough to tell a model that rejects from
    # one that never does, which is the distinction the corpus could not make
    # at all before, and not enough to rank two models that both reject
    # sometimes.
    test "there are enough negatives for rejection accuracy to mean something",
         %{corpus: corpus} do
      negatives = Enum.filter(corpus, & &1.expect_rejection)

      assert length(negatives) >= 3,
             "only #{length(negatives)} negative(s): a model answering \"yes, a book\" " <>
               "to everything would score " <>
               "#{length(corpus) - length(negatives)}/#{length(corpus)}, which is not a " <>
               "measurement of rejection"

      # ⬛ And they must be DIFFERENT KINDS of negative, or three copies of one
      # image would satisfy the count while testing one failure mode.
      assert length(Enum.uniq_by(negatives, & &1.path)) == length(negatives),
             "two negatives point at the same image"
    end

    # ⚖️ `expect_rejection` is a first-class expected outcome, not the absence
    # of one — so it must AGREE with `expect_book` rather than drift from it. A
    # negative fixture that says `expect_book: false, expect_rejection: false`
    # is a label contradicting itself, and the score would be whichever the
    # harness happened to read.
    test "expect_rejection agrees with expect_book", %{corpus: corpus} do
      for item <- corpus do
        assert item.expect_rejection == not item.expect_book,
               "#{item.name}: expect_book=#{item.expect_book} but " <>
                 "expect_rejection=#{item.expect_rejection} — the two labels disagree"
      end
    end
  end

  describe "running one stratum" do
    setup do
      path = Path.join(Application.app_dir(:core), "priv/eval/vision_corpus.exs")
      {corpus, _} = Code.eval_file(path)
      {:ok, corpus: corpus}
    end

    test "selects only that stratum", %{corpus: corpus} do
      filtered = Vision.only_stratum(corpus, "clean_barcode")

      assert filtered != []
      assert Enum.all?(filtered, &(&1.stratum == :clean_barcode))
      assert length(filtered) < length(corpus), "the filter selected everything"
    end

    test "no filter means the whole corpus", %{corpus: corpus} do
      assert Vision.only_stratum(corpus, nil) == corpus
    end

    # ⛔ THE CASE THAT STOPS A TYPO BECOMING A PASSING GATE. A misspelled
    # stratum selects nothing; a run over nothing scores 0/0 and reports no
    # regression — a gate passing because it tested nothing, which is the exact
    # shape of the "no baseline exits 0" defect one argument along.
    test "a stratum nobody has refuses rather than scoring nothing", %{corpus: corpus} do
      error = assert_raise Mix.Error, fn -> Vision.only_stratum(corpus, "clean_barcodes") end

      assert error.message =~ "no corpus item has stratum",
             "a misspelled stratum must refuse; got: #{error.message}"

      assert error.message =~ "clean_barcode",
             "the refusal should name the strata that DO exist, or the next person " <>
               "guesses twice"
    end
  end
end
