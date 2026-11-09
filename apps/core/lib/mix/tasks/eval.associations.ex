defmodule Mix.Tasks.Eval.Associations do
  @shortdoc "Replays the association corpus and scores what this code does with it"

  @moduledoc """
      Score the blog post-book association pass against a labelled corpus.

      ⛔ REPLAY BY DEFAULT, BECAUSE AN EVAL THAT NEEDS THE PROVIDER IS AN EVAL
      NOBODY RUNS ON A PR. Each corpus item carries a recorded model response;
      replaying it scores OUR half of the pass — the decoder, the id mapping,
      the de-duplication, the refusal of books that are not in the catalogue.
      That is precisely the half that broke in production twice: a Markdown
      fence the decoder did not strip, and a 500-character cap that cut the
      JSON mid-object. Neither was a model failure, and neither needed a GPU to
      find.

      ⚠️ WHAT REPLAY CANNOT TELL YOU is whether the model got better or worse.
      The expectations are labelled from each post's own text, so a replay score
      is a statement about this code against fixed inputs. Judging the model
      needs the provider.

      ## Usage

          mix eval.associations                   # replay, score against the floor
          mix eval.associations --stratum broken  # one stratum only
          mix eval.associations --verbose         # print every item

      ## The floor

      `#{inspect(__MODULE__)}` fails when the score drops below the floor
      below. The floor is a constant rather than a stored baseline because the
      inputs are fixed: unlike the vision eval, nothing here depends on a
      model's mood, so a drop is a regression in this repository and not drift.
  """
  use Mix.Task

  alias Stacks.AI.Structured

  @switches [stratum: :string, verbose: :boolean]

  # ⛔ 100%, AND IT HAS TO BE. Every expectation is a fact about code in this
  # repository applied to a fixed string — there is no provider in the loop to
  # be unlucky. A floor below 100 would be saying some of these inputs are
  # allowed to be handled wrongly, which is not a claim anyone would defend
  # out loud.
  @floor 1.0

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    {cli, _, _} = OptionParser.parse(argv, strict: @switches)

    corpus =
      load_corpus()
      |> only_stratum(Keyword.get(cli, :stratum))

    results = Enum.map(corpus, &score_item/1)

    report(results, Keyword.get(cli, :verbose, false))
    gate(results)
  end

  @doc false
  def load_corpus do
    path = Path.join(Application.app_dir(:core), "priv/eval/association_corpus.exs")
    {corpus, _} = Code.eval_file(path)
    corpus
  end

  @doc false
  # ⚠️ An empty selection RAISES rather than scoring 0/0. A misspelled stratum
  # would otherwise report no regression over nothing — a gate passing because
  # it tested nothing.
  def only_stratum(corpus, nil), do: corpus

  def only_stratum(corpus, name) do
    wanted = String.to_atom(name)

    case Enum.filter(corpus, &(&1.stratum == wanted)) do
      [] ->
        Mix.raise(
          "eval.associations: no corpus item has stratum #{inspect(wanted)}. " <>
            "Known strata: #{corpus |> Enum.map(& &1.stratum) |> Enum.uniq() |> inspect()}. " <>
            "A run over an empty selection would score 0/0 and report no regression."
        )

      filtered ->
        filtered
    end
  end

  @doc """
      What this code makes of one recorded response.

      ⚖️ Public so the suite can score an item without running the task, and
      so a reader can see the scoring is not hidden inside a pipeline.
  """
  @spec score_item(map()) :: map()
  def score_item(item) do
    got = associate(item.response, item.candidates)

    # ⚖️ `:unreadable` IS A FIRST-CLASS EXPECTED OUTCOME, not an absence of
    # one. Four items expect it, and writing them as `[]` was my own labelling
    # error: "the model said nothing we could read" and "the model found no
    # books" are different facts that want different fixes, and an expectation
    # that cannot tell them apart scores the wrong thing as right.
    expected = if is_list(item.expect), do: Enum.sort(item.expect), else: item.expect

    %{
      name: item.name,
      stratum: item.stratum,
      expected: expected,
      got: got,
      passed: got == expected,
      notes: item.notes
    }
  end

  @doc """
      The association ids this code would persist, given a response and the
      candidate books that exist.

      ⛔ MIRRORS THE WORKER'S OWN RULES, AND THE THREE THAT MATTER ARE HERE
      RATHER THAN IN THE DECODER:

      * a `book_id` that is not among the candidates is DROPPED — a post cannot
        be linked to a book that is not in the catalogue, and the ISBN hard
        gate is why;
      * the same `book_id` twice yields ONE association, so a reader's shelf
        does not gain a duplicate because the model said a title twice;
      * a decode failure yields NOTHING, loudly, rather than an empty answer —
        "the model said nothing" and "the model found nothing" are different
        facts and want different fixes.
  """
  @spec associate(String.t(), [String.t()]) :: [String.t()] | :unreadable
  def associate(response, candidates) do
    case Structured.decode(response) do
      {:ok, associations} ->
        associations
        |> Enum.map(& &1.book_id)
        |> Enum.filter(&(&1 in candidates))
        |> Enum.uniq()
        |> Enum.sort()

      {:error, _} ->
        :unreadable
    end
  end

  defp report(results, verbose?) do
    {passed, failed} = Enum.split_with(results, & &1.passed)

    Mix.shell().info("")
    Mix.shell().info("eval.associations — #{length(passed)}/#{length(results)} items")
    Mix.shell().info("")

    for {stratum, items} <- Enum.group_by(results, & &1.stratum) do
      ok = Enum.count(items, & &1.passed)
      Mix.shell().info("  #{pad(stratum)} #{ok}/#{length(items)}")
    end

    if verbose?, do: report_every_item(results)

    for r <- failed do
      Mix.shell().info("")
      Mix.shell().info("  FAIL #{r.name} (#{r.stratum})")
      Mix.shell().info("       expected #{inspect(r.expected)}")
      Mix.shell().info("       got      #{inspect(r.got)}")
      Mix.shell().info("       why it is in the corpus: #{r.notes}")
    end
  end

  defp report_every_item(results) do
    Mix.shell().info("")

    for r <- results do
      Mix.shell().info("  #{verdict(r)}  #{r.name}")
    end
  end

  defp verdict(%{passed: true}), do: "PASS"
  defp verdict(%{passed: false}), do: "FAIL"

  defp pad(stratum), do: stratum |> to_string() |> String.pad_trailing(14)

  @doc false
  def gate(results) do
    score = Enum.count(results, & &1.passed) / length(results)

    if score < @floor do
      Mix.raise("""
      eval.associations: scored #{Float.round(score * 100, 1)}%, floor is #{@floor * 100}%.

      Every expectation here is a fact about code in this repository applied to a
      fixed string — no provider is in the loop to be unlucky — so this is a
      regression in the association pass, not drift.
      """)
    end

    Mix.shell().info("")
    Mix.shell().info("eval.associations: PASS (#{Float.round(score * 100, 1)}%)")
  end
end
