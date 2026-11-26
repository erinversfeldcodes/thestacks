defmodule Mix.Tasks.Eval.Assistant do
  @shortdoc "Scores the writing assistant against the golden set, gating on per-dimension no-regression"

  @moduledoc """
      Runs the golden set through the per-dimension scorers and gates on
      no-regression against the recorded baseline.

          mix eval.assistant            # score, compare to the baseline, gate
          mix eval.assistant --record   # write this run's score as the new baseline

      Mirrors `mix eval.vision`: the gate is PER DIMENSION (never a blended
      total, so a model cannot trade faithfulness for fluency and average its way
      through), the baseline is MODEL-STAMPED (a run under a different model is a
      mismatch, not a comparison), and the failure modes that turn a gate into
      decoration are refused — an empty golden set and a missing baseline both
      RAISE rather than report 0/0.

      While the golden set is the dummy placeholder set, responses are canned and
      the model stamp is `canned`; the recorded baseline inherits
      `placeholder: true`, and `scripts/check-assistant-promoted.sh` refuses
      merge/promotion until the owner's real set flips it to false. The real eval
      runs the live assistant pipeline (retrieval + the dialogue model) on a
      deployment; this task scores whatever response each turn carries.
  """
  use Mix.Task

  alias Stacks.AI.TogetherClient
  alias Stacks.WritingAssistant.GoldenEval

  @golden_path "priv/eval/assistant_golden.exs"
  @baseline_path "priv/eval/assistant_baseline.json"

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [record: :boolean])

    golden = load_golden()
    turns = golden.turns

    if turns == [] do
      Mix.raise(
        "empty golden set: a run over nothing scores 0/0 and reports no regression, " <>
          "which is a gate passing because it tested nothing."
      )
    end

    model = model_stamp(golden)
    results = GoldenEval.score(turns)
    report(results, model)

    if opts[:record], do: record(results, model, golden.placeholder), else: gate(results, model)
  end

  defp load_golden do
    {golden, _} = Code.eval_file(Application.app_dir(:core, @golden_path))
    golden
  end

  defp model_stamp(%{placeholder: true}), do: "canned"
  defp model_stamp(_), do: TogetherClient.model()

  defp report(results, model) do
    Mix.shell().info("eval.assistant (model=#{model})")

    for dimension <- GoldenEval.dimensions() do
      counts = results[dimension]
      Mix.shell().info("  #{dimension}: #{counts.passed}/#{counts.total}")
    end
  end

  defp record(results, model, placeholder) do
    body = GoldenEval.to_baseline(results, model, placeholder)

    File.write!(
      Application.app_dir(:core, @baseline_path),
      Jason.encode!(body, pretty: true) <> "\n"
    )

    Mix.shell().info("recorded baseline -> #{@baseline_path} (placeholder=#{placeholder})")
  end

  defp gate(results, model) do
    case File.read(Application.app_dir(:core, @baseline_path)) do
      {:error, _} ->
        Mix.raise(
          "no baseline at #{@baseline_path}: nothing to compare against is not a pass. " <>
            "Run `mix eval.assistant --record` first."
        )

      {:ok, raw} ->
        baseline = Jason.decode!(raw)
        check_model(baseline["model"], model)

        case GoldenEval.compare(results, baseline["dimensions"]) do
          :ok ->
            Mix.shell().info("no per-dimension regression.")

          {:regressed, dimensions} ->
            Mix.raise(
              "per-dimension regression in: #{Enum.map_join(dimensions, ", ", &to_string/1)}. " <>
                "The gate refuses promotion."
            )
        end
    end
  end

  defp check_model(baseline_model, model) when baseline_model != model do
    Mix.raise(
      "baseline model mismatch: recorded for #{inspect(baseline_model)}, this run is " <>
        "#{inspect(model)}. A run under a different model is not comparable — re-record " <>
        "after a model swap."
    )
  end

  defp check_model(_same, _same2), do: :ok
end
