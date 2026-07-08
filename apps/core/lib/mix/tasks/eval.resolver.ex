defmodule Mix.Tasks.Eval.Resolver do
  @shortdoc "Offline eval of the title-search scorer against recorded production cases"

  @moduledoc """
  Replays recorded VLM signals + upstream OL/GB docs through the REAL
  production pick logic (`Stacks.Books.CandidateScorer.pick_best/3` —
  the exact seam `ISBNResolver.pick_best_candidate/3` calls) and checks
  each pick against the expected ISBN. Zero network: what used to be a
  30-minute deploy cycle polluted by external-API weather is a
  sub-second offline run.

  ## Usage (from `apps/core/`)

      mix eval.resolver                          # current production defaults
      mix eval.resolver --floor 3.25             # plausibility-floor experiment
      mix eval.resolver --w-derivative-penalty 0 # disable the derivative penalty
      mix eval.resolver --w-subject-hit 1.5      # any component weight
      mix eval.resolver --corpus path/to.exs     # alternative corpus

  ## Options

    * `--floor FLOAT` — plausibility floor (default:
      `CandidateScorer.default_floor/0`)
    * `--w-title-overlap`, `--w-subtitle`, `--w-subject-hit`,
      `--w-raw-text`, `--w-author`, `--w-exact-title`,
      `--w-derivative-penalty` — component weight overrides (defaults:
      `CandidateScorer.default_weights/0`)
    * `--corpus PATH` — corpus file (default: `priv/eval/corpus.exs`)

  ## Corpus

  `priv/eval/corpus.exs` — a plain Elixir list of entries; format is
  documented at the top of that file. Entries flagged
  `known_failure: true` are xfail: printed as XFAIL but excluded from
  the exit-code decision, so documented-open tuning questions don't
  block CI-style usage.

  ## Output & exit code

  Per entry: PASS/FAIL/XFAIL/XPASS with picked-vs-expected and the full
  per-candidate score table. Summary: win-rate over the whole corpus.
  Exits non-zero when any non-`known_failure` entry fails (a regression
  against pinned expectations).
  """

  use Mix.Task

  alias Stacks.Books.CandidateScorer

  @weight_switches [
    w_title_overlap: :title_overlap,
    w_subtitle: :subtitle,
    w_subject_hit: :subject_hit,
    w_raw_text: :raw_text,
    w_author: :author,
    w_exact_title: :exact_title,
    w_derivative_penalty: :derivative_penalty
  ]

  @switches [floor: :float, corpus: :string] ++
              Enum.map(@weight_switches, fn {switch, _} -> {switch, :float} end)

  @impl Mix.Task
  def run(argv) do
    # Pure module usage only — no repo, no HTTP clients, no app boot.
    Mix.Task.run("compile")
    _ = Application.load(:core)

    {cli, _, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise("eval.resolver: invalid option(s): #{inspect(invalid)}")
    end

    opts = scorer_opts(cli)
    corpus = load_corpus(cli)

    print_header(opts, cli)
    results = Enum.map(corpus, &evaluate(&1, opts))
    print_summary(results)
  end

  # --- configuration -------------------------------------------------------

  defp scorer_opts(cli) do
    weights =
      Enum.reduce(@weight_switches, [], fn {switch, weight_key}, acc ->
        case Keyword.fetch(cli, switch) do
          {:ok, value} -> [{weight_key, value} | acc]
          :error -> acc
        end
      end)

    floor = Keyword.get(cli, :floor, CandidateScorer.default_floor())
    [floor: floor, weights: weights]
  end

  defp load_corpus(cli) do
    path = Keyword.get(cli, :corpus, default_corpus_path())

    unless File.exists?(path) do
      Mix.raise("eval.resolver: corpus not found at #{path}")
    end

    {corpus, _bindings} = Code.eval_file(path)

    unless is_list(corpus) and corpus != [] do
      Mix.raise("eval.resolver: corpus at #{path} must evaluate to a non-empty list")
    end

    corpus
  end

  defp default_corpus_path do
    Application.app_dir(:core, "priv/eval/corpus.exs")
  end

  # --- evaluation ----------------------------------------------------------

  defp evaluate(entry, opts) do
    pairs = Enum.map(entry.candidates, &{&1.isbn, &1.meta})
    picked = pick(pairs, entry.signals, opts)
    scored = score_table(pairs, entry.signals, opts)
    outcome = outcome(picked, entry)

    print_entry(entry, picked, scored, outcome)
    outcome
  end

  # The production code path: identical call the resolver makes in
  # `pick_best_candidate/3` (opts default to the same production
  # defaults there).
  defp pick(pairs, signals, opts) do
    case CandidateScorer.pick_best(pairs, signals, opts) do
      :empty -> :not_found
      {:ok, {_score, isbn, _meta}, _runner_up} -> isbn
      {:floored, _best, _runner_up} -> :not_found
    end
  end

  defp score_table(pairs, signals, opts) do
    pairs
    |> Enum.map(fn {isbn, meta} ->
      {CandidateScorer.score(meta, signals, opts), isbn, meta}
    end)
    |> Enum.sort_by(&elem(&1, 0), :desc)
  end

  defp outcome(picked, entry) do
    case {picked == entry.expected, Map.get(entry, :known_failure, false)} do
      {true, false} -> :pass
      {true, true} -> :xpass
      {false, false} -> :fail
      {false, true} -> :xfail
    end
  end

  # --- output --------------------------------------------------------------

  defp print_header(opts, cli) do
    weights = Map.merge(CandidateScorer.default_weights(), Map.new(opts[:weights]))
    corpus = Keyword.get(cli, :corpus, "priv/eval/corpus.exs")

    Mix.shell().info("eval.resolver — floor=#{opts[:floor]} corpus=#{corpus}")

    Mix.shell().info(
      "weights: " <>
        Enum.map_join(Enum.sort(weights), " ", fn {k, v} -> "#{k}=#{v}" end)
    )

    Mix.shell().info("")
  end

  defp print_entry(entry, picked, scored, outcome) do
    Mix.shell().info(
      "#{label(outcome)} #{String.pad_trailing(entry.id, 26)} " <>
        "expected=#{format_pick(entry.expected)} picked=#{format_pick(picked)}"
    )

    Enum.each(scored, fn {score, isbn, meta} ->
      score_str = score |> Float.round(2) |> :erlang.float_to_binary(decimals: 2)

      Mix.shell().info(
        "        #{String.pad_leading(score_str, 6)}  #{isbn}  " <>
          "#{inspect(meta.title)} (#{meta.author || "no author"})"
      )
    end)

    Mix.shell().info("")
  end

  defp label(:pass), do: "PASS "
  defp label(:fail), do: "FAIL "
  defp label(:xfail), do: "XFAIL"
  defp label(:xpass), do: "XPASS"

  defp format_pick(:not_found), do: "not_found"
  defp format_pick(isbn), do: isbn

  defp print_summary(results) do
    counts = Enum.frequencies(results)
    pass = Map.get(counts, :pass, 0)
    fail = Map.get(counts, :fail, 0)
    xfail = Map.get(counts, :xfail, 0)
    xpass = Map.get(counts, :xpass, 0)
    total = length(results)
    wins = pass + xpass

    Mix.shell().info(
      "Summary: #{pass} pass, #{fail} fail, #{xfail} known-fail, #{xpass} xpass " <>
        "— win-rate #{wins}/#{total} (#{round(wins * 100 / total)}%)"
    )

    if xpass > 0 do
      Mix.shell().info(
        "NOTE: #{xpass} known_failure entr#{if xpass == 1, do: "y", else: "ies"} now " <>
          "pass(es) — remove the known_failure flag(s) to pin the win."
      )
    end

    if fail > 0 do
      Mix.shell().error("FAIL: #{fail} regression(s) against pinned expectations.")
      exit({:shutdown, 1})
    end
  end
end
