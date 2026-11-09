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

  @identity %{model: "qwen2-vl-7b", modal_app: "https://vision.example.test", total: 6}

  # ⚠️ `"total" => 6` to match `@identity`, which these cases build by hand
  # and which therefore carries no corpus size. The baseline is keyed to the
  # corpus as well as the model now, so a literal 6 here would make every case
  # below raise "THE CORPUS CHANGED SIZE" — true, and not what they are about.
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
      identity = Vision.model_identity(6)

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
    # ⛔ AND IT BRINGS ITS OWN BASELINE. It used to read the committed file,
    # whose contents it did not control — so when that file turned out to
    # predate model keying, this test silently started exercising a different
    # branch than the one it is named for. A test whose subject depends on a
    # tracked artefact's current contents is a test that changes meaning when
    # someone edits that artefact.
    test "an unrecognised model fails rather than passing" do
      tmp =
        Path.join(System.tmp_dir!(), "eval-mismatch-#{System.unique_integer([:positive])}.json")

      File.write!(
        tmp,
        ~s({"total": null, "passed": 2, "model": "some-other-architecture", ) <>
          ~s("modal_app": "http://localhost:8000"})
      )

      System.put_env("EVAL_VISION_BASELINE_PATH", tmp)

      on_exit(fn ->
        System.delete_env("EVAL_VISION_BASELINE_PATH")
        File.rm(tmp)
      end)

      results = [%{ok: true, name: "a", detail: ""}, %{ok: true, name: "b", detail: ""}]

      error =
        assert_raise Mix.Error, fn ->
          Vision.gate(results, false)
        end

      assert error.message =~ "NO BASELINE FOR THIS MODEL",
             "expected the model-mismatch refusal; got: #{error.message}"

      assert error.message =~ "some-other-architecture",
             "the refusal should name the model the baseline WAS recorded for, or the " <>
               "next person re-records blind"
    end

    # ⚠️ THE COMMITTED BASELINE IS A LEGACY ONE, AND THAT IS ITS OWN BRANCH.
    # `priv/eval/vision_baseline.json` carries a score and no `model`, because
    # it predates the keying. The generic mismatch message would read "recorded
    # for nil" and send whoever hits it looking for a model called nil.
    test "a baseline that names no model says so, rather than naming nil" do
      results = [%{ok: true, name: "a", detail: ""}]

      error = assert_raise Mix.Error, fn -> Vision.gate(results, false) end

      assert error.message =~ "DOES NOT SAY WHICH MODEL IT DESCRIBES",
             "expected the legacy-baseline refusal; got: #{error.message}"

      refute error.message =~ "nil",
             "the message names nil, which is the thing it exists to avoid"
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
    #
    # ⛔ AND IT RECORDS INTO A TEMP FILE, BECAUSE WITHOUT THAT IT OVERWRITES
    # THE COMMITTED BASELINE. `_build/<env>/lib/core/priv` is a SYMLINK to
    # `apps/core/priv`, so `Application.app_dir/1` under test does not reach a
    # build copy — it reaches the tracked file. One run of this test replaced
    # the real 6/6 baseline with `1/1` for a model called
    # `a-model-with-no-baseline--576460752303423033`, and only `git status`
    # caught it. A test that corrupts the artefact it is checking is worse
    # than a failing one.
    test "but recording one is still allowed" do
      tmp =
        Path.join(System.tmp_dir!(), "eval-baseline-#{System.unique_integer([:positive])}.json")

      System.put_env("EVAL_VISION_BASELINE_PATH", tmp)

      on_exit(fn ->
        System.delete_env("EVAL_VISION_BASELINE_PATH")
        File.rm(tmp)
      end)

      results = [%{ok: true, name: "a", detail: ""}]

      assert Vision.gate(results, true) != :error

      assert File.exists?(tmp),
             "recording wrote nothing to the override path, so this test is not " <>
               "exercising the recording it claims to"
    end

    # ⬛ THE GUARD ON THE GUARD. If the override is ever dropped, recording goes
    # back to writing the committed file — so this asserts the tracked baseline
    # is untouched by a recording run, which is the property that actually
    # matters rather than the mechanism that provides it.
    test "recording does not touch the committed baseline" do
      committed = Path.join(Application.app_dir(:core), "priv/eval/vision_baseline.json")
      before = File.read(committed)

      tmp =
        Path.join(System.tmp_dir!(), "eval-baseline-#{System.unique_integer([:positive])}.json")

      System.put_env("EVAL_VISION_BASELINE_PATH", tmp)

      on_exit(fn ->
        System.delete_env("EVAL_VISION_BASELINE_PATH")
        File.rm(tmp)
      end)

      Vision.gate([%{ok: true, name: "a", detail: ""}], true)

      assert File.read(committed) == before,
             "a recording run modified the committed baseline — the gate's own reference " <>
               "point, which outlives the test run"
    end
  end

  describe "the three outcomes it can reach" do
    # ⛔ ONLY ONE OF THE THREE IS EVIDENCE ABOUT THE MODEL. A wrong answer is;
    # a call that never completed is not; and a fixture the harness could not
    # read is a fact about the CORPUS. Collapsing the last two into "miss" is
    # how a moved file or a cold service gets reported as a model regression —
    # which this task did once, and the retry comment records.
    # ⛔ THIS TEST USED TO INVOKE NO PRODUCTION CODE AT ALL. It built a literal
    # and asserted facts about the literal — so it passed with
    # `lib/mix/tasks/eval.vision.ex` **deleted from the repository**, which is
    # how a reviewer found it. And it was this issue's DoD evidence for the
    # first of the three outcomes, so that row rested on nothing.
    #
    # ⚖️ Rewritten to drive `gate/2`, where the claim actually lives: a wrong
    # answer is SCORED, so it counts against the baseline and a regression is
    # reported. The distinction from an unscored case — which refuses the
    # verdict instead of failing it — is the whole point of the three outcomes,
    # and only a run can show it.
    test "a wrong answer is scored, and counts against the baseline" do
      tmp = Path.join(System.tmp_dir!(), "eval-wrong-#{System.unique_integer([:positive])}.json")
      # ⚖️ The identity is built with the SAME size this case scores — two
      # results — so the corpus-changed arm cannot fire and the case tests the
      # REGRESSION arm it is named for. Writing a mismatched total made it raise
      # "THE CORPUS CHANGED SIZE": a true refusal, for the wrong reason, with
      # the assertion still reading "REGRESSION".
      identity = Vision.model_identity(2)

      File.write!(
        tmp,
        Jason.encode!(%{
          total: Map.get(identity, :total),
          passed: 2,
          model: identity.model,
          modal_app: identity.modal_app
        })
      )

      System.put_env("EVAL_VISION_BASELINE_PATH", tmp)

      on_exit(fn ->
        System.delete_env("EVAL_VISION_BASELINE_PATH")
        File.rm(tmp)
      end)

      results = [
        %{ok: true, name: "a", detail: ""},
        %{ok: false, name: "b", detail: "is_book=false"}
      ]

      error = assert_raise Mix.Error, fn -> Vision.gate(results, false) end

      assert error.message =~ "REGRESSION",
             "a wrong answer must count against the baseline; got: #{error.message}"

      assert error.message =~ "1/2",
             "the refusal should carry the score it reached"
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
    @corpus_fields [:name, :path, :stratum, :expect_book, :provenance, :notes]

    setup do
      path = Path.join(Application.app_dir(:core), "priv/eval/vision_corpus.exs")
      {corpus, _} = Code.eval_file(path)

      # ⛔ NON-EMPTINESS LIVES HERE, NOT IN ONE TEST. It used to be an
      # `assert length(corpus) >= 8` inside the field-coverage case — so with
      # the corpus emptied to `[]`, that case reddened and **two siblings stayed
      # green**: the provenance guard (the one defending the no-user-images
      # rule) and the label-agreement one. Both are bare `for item <- corpus`
      # loops, vacuous over nothing. The anti-vacuity check was in the test that
      # needed it least. Measured again after hoisting: an empty corpus now reds
      # every case in this block.
      #
      # ⚖️ And it is ONLY non-emptiness. The size floor is a separate named
      # assertion below, because conflating the two means the first legitimate
      # fixture deletion reds a test whose message says "the corpus shrank" —
      # literally correct, and cheapest to resolve by lowering the number.
      refute corpus == [], "the corpus is empty, so every case in this block is vacuous"
      {:ok, corpus: corpus}
    end

    test "every item carries the corpus plan's section-3 fields", %{corpus: corpus} do
      for item <- corpus, field <- @corpus_fields do
        assert Map.has_key?(item, field),
               "#{inspect(Map.get(item, :name, item))} is missing #{inspect(field)}"
      end
    end

    # ⚖️ THE SIZE FLOOR, NAMED SEPARATELY from the non-emptiness guard in
    # `setup`. This is the one that gets edited rather than investigated: a
    # legitimate fixture deletion reds it, and the cheapest resolution is to
    # lower the number. Keeping it distinct means nobody can satisfy
    # anti-vacuity by doing that.
    test "the corpus has not shrunk below what rejection scoring needs", %{corpus: corpus} do
      assert length(corpus) >= 8,
             "the corpus holds #{length(corpus)} fixtures; eight is what makes three " <>
               "negatives a meaningful fraction of it"
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
      # ⚖️ DERIVED, not declared. `expect_rejection` was a second field that had
      # to agree with `expect_book` — and a test enforcing agreement between two
      # fields is the expensive substitute for having one. Nothing in `lib/`,
      # `scripts/` or the workflows ever read it.
      negatives = Enum.reject(corpus, & &1.expect_book)

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

  describe "a baseline recorded before baselines named their model" do
    # ⛔ THE COMMITTED BASELINE IS ONE OF THESE, AND THIS CHANGE MAKES THE
    # DEPLOY GATE FAIL ON IT.
    #
    # `priv/eval/vision_baseline.json` carries `{"total": 6, "passed": 6,
    # "recorded_at": …}` and no `model`, because it was recorded before scores
    # were keyed by the model they describe. That is the right outcome — a
    # score with no model cannot support a no-regression claim for any model —
    # but the generic mismatch message would read "recorded for nil" and send
    # whoever hits it looking for a model called nil.
    #
    # ⚠️ PR CI never runs this path; only a deploy does. So the message is the
    # whole of the help available at the moment it fires.
    test "it says the baseline names no model, not that the model is nil" do
      identity = %{model: "Qwen/Qwen2.5-VL-7B-Instruct", modal_app: "https://example.test"}
      legacy = ~s({"total": 6, "passed": 6, "recorded_at": "2026-08-20T10:08:09Z"})

      assert {:mismatch, nil} = Vision.baseline_for(legacy, identity)
    end

    test "a baseline naming a DIFFERENT model is a different case" do
      identity = %{model: "new-architecture", modal_app: "https://example.test"}

      recorded =
        ~s({"total": null, "passed": 6, "model": "Qwen/Qwen2.5-VL-7B-Instruct", ) <>
          ~s("modal_app": "https://example.test"})

      assert {:mismatch, "Qwen/Qwen2.5-VL-7B-Instruct"} = Vision.baseline_for(recorded, identity)
    end

    # ⬛ ANTI-VACUITY: a baseline that DOES match must still be accepted, or the
    # two cases above would be satisfied by a function that mismatched always.
    test "a matching baseline is accepted" do
      identity = %{model: "m", modal_app: "https://example.test"}

      recorded =
        ~s({"total": null, "passed": 6, "model": "m", "modal_app": "https://example.test"})

      assert {:ok, 6} = Vision.baseline_for(recorded, identity)
    end
  end

  describe "what the baseline is keyed to" do
    # ⛔ THE IDENTITY WAS A CONSTANT, SO THE BASELINE WAS STILL INHERITED.
    #
    # `model_identity/0` read `:core, :vision_model` — set **nowhere in this
    # repository**, only by a test. Every real run therefore scored as
    # `"unknown"`, and the gate printed it: "no regression (baseline 6 for
    # unknown)". The only varying component was the service URL, and a redesign
    # deploys to the same Modal app, so a new architecture would have inherited
    # the previous model's number. The requirement this keying exists for was
    # true in the suite and false in every environment.
    #
    # ⚖️ `/analyze` returns `model_used` and `Stacks.Moderation` already reads
    # it. It was on the very response the eval parsed and discarded.
    test "a model the service named beats the config default" do
      Application.put_env(:core, :vision_model, "from-config")
      on_exit(fn -> Application.delete_env(:core, :vision_model) end)

      assert Vision.model_identity(6).model == "from-config"

      # What a scored image leaves behind.
      Process.put({Vision, :model_used}, "what-the-service-said")

      assert Vision.model_identity(6).model == "what-the-service-said",
             "the config value won over the service's own answer — which is how a " <>
               "redesign inherits the previous model's baseline"
    end

    # ⬛ AND `"unknown"` IS STILL REACHABLE, deliberately: `model_identity/0` is
    # called before any image has been scored (by `--record` and by this suite),
    # so the fallback has to exist. What changed is that it is no longer the
    # ONLY value a real run can produce.
    test "with nothing scored and nothing configured it is unknown" do
      Process.delete({Vision, :model_used})
      Application.delete_env(:core, :vision_model)

      assert Vision.model_identity(6).model == "unknown"
    end
  end

  describe "the record an INCOMPLETE run leaves" do
    # ⛔ IT LEFT NONE, AND THAT IS THE RUN MOST WORTH LOOKING AT LATER.
    #
    # `write_run_artefact/5` sat BELOW the unscored check's `Mix.raise`, so
    # "written before the verdict" was true of every baseline branch and false
    # of the one outcome a cold Modal service actually produces. A gate that
    # records every failure except the transport ones has no history of the
    # thing that goes wrong most.
    test "an unscored run still writes its artefact" do
      tmp = Path.join(System.tmp_dir!(), "eval-run-#{System.unique_integer([:positive])}.json")
      System.put_env("EVAL_VISION_RESULT_PATH", tmp)

      on_exit(fn ->
        System.delete_env("EVAL_VISION_RESULT_PATH")
        File.rm(tmp)
      end)

      results = [
        %{ok: true, name: "a", detail: ""},
        %{ok: false, name: "b", detail: "call failed", unscored: true}
      ]

      error = assert_raise Mix.Error, fn -> Vision.gate(results, false) end

      assert error.message =~ "INCOMPLETE"

      assert File.exists?(tmp),
             "the INCOMPLETE run left no artefact — the outcome a cold service produces " <>
               "is the one with no record"

      assert {:ok, %{"unscored" => 1}} = tmp |> File.read!() |> Jason.decode()
    end
  end

  describe "the baseline is keyed to the corpus, not just the model" do
    # ⛔ `total` WAS WRITTEN AND NEVER READ, so a 6/6 baseline cleared an
    # 8-fixture run scoring 6 — **both negatives this branch added could fail
    # and the gate would report no regression.** The reviewer's probe printed
    # exactly that: `score: 6/8` → `no regression (baseline 6 for unknown)`.
    #
    # ⚖️ A changed corpus is its own refusal rather than a regression: the old
    # number cannot be compared to the new one in either direction, so claiming
    # "regressed" would be a claim the data does not support.
    test "a baseline over a smaller corpus is refused, not compared" do
      identity = %{model: "m", modal_app: "https://example.test", total: 8}

      body = Jason.encode!(%{passed: 6, total: 6, model: "m", modal_app: "https://example.test"})

      assert {:different_corpus, 6} = Vision.baseline_for(body, identity)
    end

    # ⬛ ANTI-VACUITY: the SAME corpus size must still compare, or the case
    # above would be satisfied by a function that refused every baseline.
    test "the same corpus size compares" do
      identity = %{model: "m", modal_app: "https://example.test", total: 8}

      body = Jason.encode!(%{passed: 6, total: 8, model: "m", modal_app: "https://example.test"})

      assert {:ok, 6} = Vision.baseline_for(body, identity)
    end

    # ⚠️ And the model mismatch still wins, because it is the more fundamental
    # disagreement: a different model's number is not comparable whatever the
    # corpus did.
    test "a different model is reported as such even when the corpus also changed" do
      identity = %{model: "new", modal_app: "https://example.test", total: 8}

      body =
        Jason.encode!(%{passed: 6, total: 6, model: "old", modal_app: "https://example.test"})

      assert {:mismatch, "old"} = Vision.baseline_for(body, identity)
    end
  end

  describe "a baseline written the way the task writes one" do
    # ⛔ MY FIXTURES AGREED WITH A FILE THE TASK CANNOT PRODUCE.
    #
    # The corpus size used to reach `model_identity/0` through the process
    # dictionary, set once at corpus selection — so a direct `gate/2` call left
    # it `nil`, while a baseline written by `write_baseline/4` always carries a
    # number. I then wrote `"total" => nil` into every fixture to stop the
    # cases tripping "THE CORPUS CHANGED SIZE", which made the suite agree with
    # a shape nothing emits. Measured at the time: a real artefact against a
    # direct identity gave `{:different_corpus, 6}` where the hand-written
    # fixture gave `{:ok, 6}`.
    #
    # ⚖️ This case closes that gap by round-tripping the task's OWN writer into
    # its own reader, so no hand-written shape can stand in for the real one.
    test "the task's own writer produces a baseline its own reader accepts" do
      tmp = Path.join(System.tmp_dir!(), "eval-rt-#{System.unique_integer([:positive])}.json")
      System.put_env("EVAL_VISION_BASELINE_PATH", tmp)

      on_exit(fn ->
        System.delete_env("EVAL_VISION_BASELINE_PATH")
        File.rm(tmp)
      end)

      results = [
        %{ok: true, name: "a", detail: ""},
        %{ok: true, name: "b", detail: ""}
      ]

      # Record, then read back with the identity the same run would compute.
      Vision.gate(results, true)

      assert {:ok, 2} = Vision.baseline_for(File.read!(tmp), Vision.model_identity(2)),
             "the baseline this task wrote is not one it will accept — the writer and " <>
               "the reader disagree about a field, which a hand-written fixture cannot show"
    end

    # ⬛ AND A GENUINELY DIFFERENT CORPUS IS STILL REFUSED, so the case above
    # cannot pass by the comparison having been dropped.
    test "the same baseline is refused once the corpus has changed size" do
      tmp = Path.join(System.tmp_dir!(), "eval-rt2-#{System.unique_integer([:positive])}.json")
      System.put_env("EVAL_VISION_BASELINE_PATH", tmp)

      on_exit(fn ->
        System.delete_env("EVAL_VISION_BASELINE_PATH")
        File.rm(tmp)
      end)

      Vision.gate([%{ok: true, name: "a", detail: ""}], true)

      assert {:different_corpus, 1} =
               Vision.baseline_for(File.read!(tmp), Vision.model_identity(8))
    end
  end
end
