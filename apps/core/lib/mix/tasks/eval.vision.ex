defmodule Mix.Tasks.Eval.Vision do
  @shortdoc "Scores the vision service against the labelled corpus, gating on no regression"

  @moduledoc """
      Runs every image in `priv/eval/vision_corpus.exs` through the REAL vision
      seam (`Stacks.AI.Client.call_vision/2`, the same call the upload path makes)
      and scores the answers against their labels.

          mix eval.vision                  # score, compare to the baseline, gate
          mix eval.vision --record         # write today's score as the new baseline
          mix eval.vision --corpus path    # an alternative corpus

      ## Why this gates on no-regression rather than a threshold

      Six fixtures. One image changing its mind moves an accuracy percentage by
      16.7 points, so an "≥90%" gate would fire on noise, and the first time it
      went red for a benign reason someone would raise the threshold rather than
      investigate — which is how a gate becomes decoration. Instead the score is
      compared against `priv/eval/vision_baseline.json` and the task fails only
      when it gets WORSE. That detects breakage honestly on the corpus we have.

      `docs/vision-eval-corpus-plan.md` specifies the ~120-image corpus that
      would make per-stratum absolute thresholds defensible. Expanding to it is
      deferred, deliberately, and this moduledoc is where that promise lives.

      ## Why it can skip, and why the skip is loud

      Scoring needs a real GPU behind the vision endpoint. With no endpoint
      configured the task SKIPS — but says so on stdout and exits 0 only because
      "not run" is not "regressed". A caller that needs the gate enforced sets
      `EVAL_VISION_REQUIRED=1`, which turns the skip into a failure. That switch
      exists because a gate that quietly no-ops when its dependency is missing is
      the exact shape of a gate everyone believes in and nobody runs.
  """

  use Mix.Task

  alias Stacks.AI.Client

  @switches [record: :boolean, corpus: :string, stratum: :string]
  @baseline_path "priv/eval/vision_baseline.json"
  @call_attempts 3
  @retry_pause_ms 30_000

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    {cli, _, _} = OptionParser.parse(argv, strict: @switches)

    corpus =
      cli
      |> Keyword.get(:corpus)
      |> load_corpus()
      |> only_stratum(Keyword.get(cli, :stratum))

    point_client_at_configured_service()

    if skip?() do
      skip_or_fail()
    else
      results = Enum.map(corpus, &score_image/1)
      report(results)
      gate(results, Keyword.get(cli, :record, false))
    end
  end

  @doc false
  # ⛔ A STRATUM FILTER, AND IT REFUSES AN EMPTY SELECTION. `--stratum
  # clean_barcode` runs only the tier that needs no GPU, which is what makes an
  # every-PR run conceivable at all — the VLM tiers need a deployed service.
  #
  # ⚠️ A misspelled stratum selects nothing, and a run over nothing would score
  # 0/0 and report no regression — a gate passing because it tested nothing,
  # which is the shape this whole issue exists to remove. So an empty selection
  # raises rather than scoring.
  def only_stratum(corpus, nil), do: corpus

  def only_stratum(corpus, name) do
    wanted = String.to_atom(name)

    case Enum.filter(corpus, &(&1.stratum == wanted)) do
      [] ->
        Mix.raise(
          "eval.vision: no corpus item has stratum #{inspect(wanted)}. " <>
            "Known strata: #{corpus |> Enum.map(& &1.stratum) |> Enum.uniq() |> inspect()}. " <>
            "A run over an empty selection would score 0/0 and report no regression."
        )

      filtered ->
        filtered
    end
  end

  # `config/runtime.exs` only reads VISION_SERVICE_URL when PHX_SERVER is set, so
  # outside a running server the compile-time default (`http://localhost:8000`)
  # wins and every call dies on econnrefused against a service that was never
  # there. Setting the env var is how you say "score THIS deployment", and this
  # is the task that acts on it — otherwise the variable silently means nothing
  # and the failures look like the model rather than the wiring.
  defp point_client_at_configured_service do
    case System.get_env("VISION_SERVICE_URL") do
      nil -> :ok
      "" -> :ok
      url -> Application.put_env(:core, :vision_service_url, url)
    end
  end

  defp skip?, do: is_nil(System.get_env("VISION_SERVICE_URL")) and Mix.env() != :test

  defp skip_or_fail do
    msg =
      "eval.vision: SKIPPED — VISION_SERVICE_URL is not set, so there is no vision " <>
        "service to score against. This is not a pass."

    if System.get_env("EVAL_VISION_REQUIRED") == "1" do
      Mix.raise(msg <> " EVAL_VISION_REQUIRED=1 is set, so a skip is a failure.")
    else
      Mix.shell().info(msg)
    end
  end

  defp load_corpus(nil),
    do: load_corpus(Application.app_dir(:core, "priv/eval/vision_corpus.exs"))

  defp load_corpus(path) do
    path = if File.exists?(path), do: path, else: Path.join(File.cwd!(), path)
    {corpus, _} = Code.eval_file(path)
    corpus
  end

  @doc false
  # ⚠️ Public for the unreadable branch specifically, which returns BEFORE any
  # service call and so is the one outcome of the three that can be asserted
  # without a network. The other two need a live service and are covered at
  # `gate/2`, where the decision they feed actually lives.
  def score_image(%{path: path} = item) do
    full = Path.join(root(), path)

    case File.read(full) do
      # ⛔ UNSCORED, NOT A MISS. A fixture the harness cannot read is a fact
      # about the CORPUS — it was moved, renamed, or never committed — and
      # scoring it as a wrong answer makes the corpus's own decay look like the
      # model regressing. The three outcomes this task can reach are "wrong
      # answer", "could not ask" and "could not read the question", and only the
      # first is evidence about the model.
      {:error, reason} ->
        Map.merge(item, %{
          ok: false,
          unscored: true,
          detail: "unreadable fixture (#{inspect(reason)}) — the corpus, not the model"
        })

      {:ok, bytes} ->
        b64 = Base.encode64(bytes)

        case analyze_with_retry(b64, @call_attempts) do
          {:error, reason} ->
            Map.merge(item, %{
              ok: false,
              unscored: true,
              detail: "call failed after #{@call_attempts} attempt(s): #{inspect(reason)}"
            })

          {classified, isbns} ->
            book_ok = classified == item.expect_book
            isbn_ok = is_nil(item.expect_isbn) or item.expect_isbn in isbns

            Map.merge(item, %{
              ok: book_ok and isbn_ok,
              detail: "is_book=#{classified} isbns=#{inspect(Enum.take(isbns, 3))}"
            })
        end
    end
  end

  # A failed CALL is not a wrong ANSWER. A freshly deployed service answers its
  # first heavy request only after loading the model, and past the HTTP window
  # the platform answers 303 instead of waiting — so the failed first call IS
  # the warmup, and a retry scores the now-warm service. Only after the
  # attempts are spent does the case become unscored — never a wrong answer,
  # because counting it as one once reported a cold cache as "model regressed".
  defp analyze_with_retry(b64, attempts) when attempts > 1 do
    case analyze(b64) do
      {:error, _reason} ->
        Process.sleep(@retry_pause_ms)
        analyze_with_retry(b64, attempts - 1)

      scored ->
        scored
    end
  end

  defp analyze_with_retry(b64, _last), do: analyze(b64)

  # The production seam exactly: `Stacks.Moderation` posts `%{image: b64}` to
  # /analyze and reads a CLASSIFICATION_RESULT_* enum plus a `books` list, each
  # entry carrying `potential_isbns`. One call answers both questions this corpus
  # asks. Scoring against a different endpoint or payload shape would measure
  # something no reader ever exercises — an earlier draft called /classify with
  # `%{image_b64: ...}` and got `malformed_request` from a perfectly healthy
  # service, which reads as a model failure and is not one.
  #
  # proto-enum-coverage: ClassificationResult ignore
  #   CLASSIFICATION_RESULT_AMBIGUOUS, CLASSIFICATION_RESULT_NOT_BOOK
  #   — this comparison answers one question, "did the model call this a book?",
  #   and for both the answer is no. AMBIGUOUS counts as "not a book" because the
  #   upload path cannot shelve an ambiguous result either, so scoring it as a
  #   hit would flatter the model against what a reader actually gets. Naming
  #   them separately would let the two agree in the enum and disagree here.
  defp analyze(b64) do
    case Client.call_vision("analyze", %{image: b64}) do
      {:ok, %{"classification" => classification} = resp} ->
        isbns =
          resp
          |> Map.get("books", [])
          |> Enum.flat_map(fn b -> Map.get(b, "potential_isbns") || [] end)

        {classification == "CLASSIFICATION_RESULT_BOOK", isbns}

      other ->
        {:error, other}
    end
  end

  defp root do
    # The fixtures sit at the umbrella root, but this task may be invoked from
    # there or from apps/core, and `Application.app_dir/1` points into _build.
    # Walk up until the images directory is actually found rather than counting
    # "../" levels against one assumed working directory.
    Enum.reduce_while(0..6, File.cwd!(), fn _, dir ->
      if File.dir?(Path.join(dir, "images")),
        do: {:halt, dir},
        else: {:cont, Path.expand("..", dir)}
    end)
  end

  defp report(results) do
    Mix.shell().info("\nvision eval — #{length(results)} image(s)\n")

    Enum.each(results, fn r ->
      mark =
        cond do
          Map.get(r, :unscored, false) -> "----"
          r.ok -> "ok  "
          true -> "FAIL"
        end

      Mix.shell().info("  #{mark} #{String.pad_trailing(r.name, 18)} #{r.detail}")
    end)

    Mix.shell().info("\nby stratum:")

    Enum.each(per_stratum(results), fn {stratum, counts} ->
      Mix.shell().info(
        "  #{String.pad_trailing(to_string(stratum), 20)} " <>
          "#{counts.passed}/#{counts.scored}" <>
          if(counts.unscored > 0, do: "  (#{counts.unscored} unscored)", else: "")
      )
    end)
  end

  @doc false
  # ⛔ REPORTED, NOT GATED, AND THE DIFFERENCE IS THE CORPUS SIZE. Six fixtures
  # cannot carry a per-stratum THRESHOLD — one image changing its mind moves a
  # stratum's score by a third, which reads as rigour and behaves as noise. But
  # a whole-corpus number hides WHERE a regression landed, and "the barcode tier
  # got worse while the VLM tier got better" is the single most useful sentence
  # this harness can produce for the redesign.
  #
  # ⚖️ So the breakdown is printed and recorded now, and becomes gateable when
  # the corpus reaches the size the corpus plan specifies.
  #
  # ⚠️ `scored` excludes the unscored, so a stratum whose fixtures all went
  # missing reads `0/0` with its unscored count beside it — not `0/3`, which
  # would be indistinguishable from a model that got every one wrong.
  def per_stratum(results) do
    results
    |> Enum.group_by(&Map.get(&1, :stratum, :unknown))
    |> Enum.map(fn {stratum, rows} ->
      unscored = Enum.count(rows, &Map.get(&1, :unscored, false))

      {stratum,
       %{
         passed: Enum.count(rows, & &1.ok),
         scored: length(rows) - unscored,
         unscored: unscored
       }}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc false
  # ⚠️ Public for the same reason the baseline reader is: this is the decision a
  # deploy gate makes, and asserting it by running the task would need a live
  # vision service — which is how it came to have no test at all.
  def gate(results, record?) do
    passed = Enum.count(results, & &1.ok)
    total = length(results)
    unscored = Enum.count(results, &Map.get(&1, :unscored, false))
    Mix.shell().info("\nscore: #{passed}/#{total}")

    # An unscored case poisons both verdicts: the score can neither prove a
    # regression (the model never answered) nor clear the gate (the baseline
    # counts every case). Say that, in words deploy-stack.sh classifies as a
    # broken gate rather than a scored regression — it greps for REGRESSION.
    if unscored > 0 and not record? do
      Mix.raise(
        "eval.vision: INCOMPLETE — #{unscored} of #{total} case(s) could not be scored " <>
          "(the call failed; that is transport, not a model answer). " <>
          "No regression is claimed and no pass is granted on a partial score."
      )
    end

    baseline_file = baseline_file()
    identity = model_identity()

    # ⛔ WRITTEN BEFORE THE VERDICT, deliberately. Every branch below can
    # `Mix.raise`, and an artefact written after the decision would exist only
    # for runs that passed — so the runs most worth looking at later, the ones
    # that failed, would leave nothing behind. A gate that records only its
    # successes is a gate with no history.
    write_run_artefact(results, passed, total, unscored, identity)
    baseline = read_baseline(baseline_file, identity)

    verdict(baseline, baseline_file, passed, total, identity, record?)
  end

  # ⚖️ THE DECISION, SPLIT OUT OF THE SCORING. `gate/2` counts and records;
  # this says yes or no. They were one function until it crossed the
  # complexity limit, and the split is the better shape regardless: the
  # counting is arithmetic, the verdict is policy, and only one of them has
  # five ways to refuse.
  defp verdict(baseline, baseline_file, passed, total, identity, record?) do
    cond do
      record? ->
        write_baseline(baseline_file, passed, total, identity)
        Mix.shell().info("recorded #{passed}/#{total} as the new baseline for #{identity.model}")

      baseline == :absent ->
        Mix.raise(refusal(:absent, passed, total, identity, baseline))

      baseline == :unreadable ->
        Mix.raise(refusal(:unreadable, passed, total, identity, baseline))

      match?({:mismatch, nil}, baseline) ->
        Mix.raise(refusal(:legacy_baseline, passed, total, identity, baseline))

      match?({:mismatch, _}, baseline) ->
        Mix.raise(refusal(:other_model, passed, total, identity, baseline))

      elem(baseline, 1) > passed ->
        Mix.raise(refusal(:regression, passed, total, identity, baseline))

      true ->
        Mix.shell().info("no regression (baseline #{elem(baseline, 1)} for #{identity.model})")
    end
  end

  # ⚖️ THE REFUSALS LIVE TOGETHER, so the five ways this gate can decline are
  # readable side by side rather than scattered down a `cond`. They are the
  # whole of the help available at the moment one fires — a deploy gate's
  # message is read by someone who did not write it, under time pressure.
  defp refusal(:absent, passed, total, _identity, _baseline) do
    # ⛔ This used to print a note and exit 0 — a gate with nothing to compare
    # against reporting success, which is the house failure mode: the deploy
    # gate passed on every stack that had never recorded a baseline, and
    # "nothing is being gated" read as "nothing is wrong".
    "eval.vision: NO BASELINE — nothing to compare #{passed}/#{total} against. " <>
      "Run `mix eval.vision --record` to pin this score. A gate with no baseline " <>
      "grants no pass."
  end

  defp refusal(:unreadable, _passed, _total, _identity, _baseline) do
    "eval.vision: UNREADABLE BASELINE — the file exists and could not be parsed, " <>
      "which is not the same as having none. Fix or re-record it."
  end

  # ⚠️ A BASELINE RECORDED BEFORE BASELINES NAMED THEIR MODEL. The committed
  # file predates the keying, so it carries a score and no `model` — and
  # "recorded for nil" would send whoever hits it looking for a model called
  # nil. It cannot support a no-regression claim for ANY model, which is the
  # thing to say.
  defp refusal(:legacy_baseline, passed, total, identity, _baseline) do
    "eval.vision: THE BASELINE DOES NOT SAY WHICH MODEL IT DESCRIBES — scored " <>
      "#{passed}/#{total} as #{identity.model}, against a baseline recorded " <>
      "before baselines were keyed by model. A score is a fact about a model, so " <>
      "this one cannot support a no-regression claim for any of them. " <>
      "Run `mix eval.vision --record` against the deployed service to replace it."
  end

  defp refusal(:other_model, passed, total, identity, {:mismatch, recorded_model}) do
    "eval.vision: NO BASELINE FOR THIS MODEL — scored #{passed}/#{total} as " <>
      "#{identity.model}, but the baseline was recorded for " <>
      "#{inspect(recorded_model)}. A new architecture earns its own baseline " <>
      "rather than inheriting one that describes a different system. " <>
      "Run `mix eval.vision --record`."
  end

  defp refusal(:regression, passed, total, identity, baseline) do
    "eval.vision: REGRESSION — scored #{passed}/#{total}, baseline is " <>
      "#{elem(baseline, 1)} for #{identity.model}. " <>
      "Something the vision service used to get right it now gets wrong."
  end

  # ⛔ OVERRIDABLE, BECAUSE `Application.app_dir/1` REACHES THE TRACKED FILE.
  #
  # In a Mix project `_build/<env>/lib/core/priv` is a SYMLINK to
  # `apps/core/priv`, so a `--record` run under test does not write a build
  # copy — it writes the committed `vision_baseline.json`. One such run
  # replaced the real 6/6 baseline with `1/1` for a model named
  # `a-model-with-no-baseline--576460752303423033`, and the only reason it was
  # noticed is that `git status` showed the file dirty.
  #
  # ⚠️ A test that can overwrite a tracked artefact is worse than a failing
  # test: it corrupts the gate it is checking, and the corruption outlives the
  # run. `EVAL_VISION_BASELINE_PATH` is how the suite keeps its recording in a
  # temp directory; nothing sets it in production, where the app-dir path is
  # the right one.
  defp baseline_file do
    System.get_env("EVAL_VISION_BASELINE_PATH") ||
      Path.join(Application.app_dir(:core), @baseline_path)
  end

  @doc false
  # ⛔ THE BASELINE IS KEYED BY MODEL IDENTITY, and that is the whole point of
  # this function rather than a detail of it.
  #
  # A score is a fact about a MODEL, not about the corpus. Reading only
  # `"passed"` meant a new architecture inherited the VLM's number — so the
  # first candidate for the vision redesign would have been gated against a
  # baseline describing a different system, and either cleared or failed for a
  # reason that had nothing to do with it.
  #
  # ⚖️ An identity mismatch is NOT a regression. It means "nothing to compare
  # against", which is the `:no_baseline` case — a new model earns its own
  # baseline rather than borrowing one.
  def baseline_for(body, identity) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"passed" => passed} = recorded} ->
        if Map.get(recorded, "model") == identity.model and
             Map.get(recorded, "modal_app") == identity.modal_app do
          {:ok, passed}
        else
          {:mismatch, Map.get(recorded, "model")}
        end

      _ ->
        :unreadable
    end
  end

  defp read_baseline(file, identity) do
    case File.read(file) do
      {:ok, body} -> baseline_for(body, identity)
      {:error, _} -> :absent
    end
  end

  defp write_baseline(file, passed, total, identity) do
    File.mkdir_p!(Path.dirname(file))

    File.write!(
      file,
      Jason.encode!(
        %{
          passed: passed,
          total: total,
          model: identity.model,
          modal_app: identity.modal_app,
          recorded_at: DateTime.utc_now()
        },
        pretty: true
      )
    )
  end

  # ⚖️ The path is overridable so CI can collect it as a build artefact and a
  # test can write somewhere disposable; it defaults beside the baseline, which
  # is where someone looking for "what happened last run" would think to look.
  defp write_run_artefact(results, passed, total, unscored, identity) do
    file =
      System.get_env("EVAL_VISION_RESULT_PATH") ||
        Path.join(Application.app_dir(:core), "priv/eval/vision_last_run.json")

    payload = %{
      model: identity.model,
      modal_app: identity.modal_app,
      passed: passed,
      total: total,
      unscored: unscored,
      ran_at: DateTime.utc_now(),
      per_stratum:
        Map.new(per_stratum(results), fn {stratum, counts} -> {to_string(stratum), counts} end),
      cases:
        Enum.map(results, fn r ->
          %{
            name: r.name,
            stratum: Map.get(r, :stratum, :unknown),
            ok: r.ok,
            unscored: Map.get(r, :unscored, false),
            detail: r.detail
          }
        end)
    }

    File.mkdir_p!(Path.dirname(file))
    File.write!(file, Jason.encode!(payload, pretty: true))
    Mix.shell().info("\nrun recorded to #{file}")
  rescue
    # ⚠️ A record that cannot be written must not take the gate down with it.
    # The verdict is the task's job; the artefact is for whoever reads it later.
    error ->
      Mix.shell().info("could not write the run artefact: #{inspect(error)}")
      :ok
  end

  @doc false
  # ⚠️ WHAT WAS SCORED, read from the same config the service call uses, so a
  # baseline cannot be recorded against one model and compared against another
  # without the identity changing too.
  def model_identity do
    %{
      model: Application.get_env(:core, :vision_model, "unknown"),
      modal_app: Application.get_env(:core, :vision_service_url, "unknown")
    }
  end
end
