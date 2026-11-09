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

  @switches [record: :boolean, corpus: :string]
  @baseline_path "priv/eval/vision_baseline.json"
  @call_attempts 3
  @retry_pause_ms 30_000

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    {cli, _, _} = OptionParser.parse(argv, strict: @switches)

    corpus = load_corpus(Keyword.get(cli, :corpus))
    point_client_at_configured_service()

    if skip?() do
      skip_or_fail()
    else
      results = Enum.map(corpus, &score_image/1)
      report(results)
      gate(results, Keyword.get(cli, :record, false))
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
      mark = if r.ok, do: "ok  ", else: "FAIL"
      Mix.shell().info("  #{mark} #{String.pad_trailing(r.name, 18)} #{r.detail}")
    end)
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

    baseline_file = Path.join(Application.app_dir(:core), @baseline_path)
    identity = model_identity()
    baseline = read_baseline(baseline_file, identity)

    cond do
      record? ->
        write_baseline(baseline_file, passed, total, identity)
        Mix.shell().info("recorded #{passed}/#{total} as the new baseline for #{identity.model}")

      # ⛔ FAILS. This used to print a note and exit 0 — a gate with nothing to
      # compare against reporting success, which is the house failure mode: the
      # deploy gate passed on every stack that had never recorded a baseline,
      # and "nothing is being gated" read as "nothing is wrong".
      baseline == :absent ->
        Mix.raise(
          "eval.vision: NO BASELINE — nothing to compare #{passed}/#{total} against. " <>
            "Run `mix eval.vision --record` to pin this score. A gate with no baseline " <>
            "grants no pass."
        )

      baseline == :unreadable ->
        Mix.raise(
          "eval.vision: UNREADABLE BASELINE — the file exists and could not be parsed, " <>
            "which is not the same as having none. Fix or re-record it."
        )

      match?({:mismatch, _}, baseline) ->
        {:mismatch, recorded_model} = baseline

        Mix.raise(
          "eval.vision: NO BASELINE FOR THIS MODEL — scored #{passed}/#{total} as " <>
            "#{identity.model}, but the baseline was recorded for " <>
            "#{inspect(recorded_model)}. A new architecture earns its own baseline " <>
            "rather than inheriting one that describes a different system. " <>
            "Run `mix eval.vision --record`."
        )

      elem(baseline, 1) > passed ->
        Mix.raise(
          "eval.vision: REGRESSION — scored #{passed}/#{total}, baseline is " <>
            "#{elem(baseline, 1)} for #{identity.model}. " <>
            "Something the vision service used to get right it now gets wrong."
        )

      true ->
        Mix.shell().info("no regression (baseline #{elem(baseline, 1)} for #{identity.model})")
    end
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
