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
    # ⚖️ `app.config`, NOT `app.start`. This eval reads one file and decodes
    # strings: there is no provider, no network and no database in it. Starting
    # the application booted nine circuit breakers and opened a DB connection to
    # do that, which is cost with no purpose — and on a PR runner it is the only
    # thing in the job that needs a configured environment at all. Loading is
    # enough for `Application.app_dir/1` to resolve the corpus path.
    Mix.Task.run("app.config")
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
    got = associate(item.response)

    # ⚖️ `:unreadable` IS A FIRST-CLASS EXPECTED OUTCOME, not an absence of
    # one. Four items expect it, and writing them as `[]` was my own labelling
    # error: "the model said nothing we could read" and "the model found no
    # books" are different facts that want different fixes, and an expectation
    # that cannot tell them apart scores the wrong thing as right.
    # ⚖️ ORDER IS PRESERVED, NOT SORTED. The decoder reports what the model said
    # in the order it said it, and the worker's `list_associations/1` orders by
    # confidence afterwards — so sorting here would hide a decoder that
    # reordered or dropped-and-reappended. The expectations are written in the
    # response's own order.
    expected = item.expect

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
      The book ids a response yields, as the DECODER reads it.

      ⛔ THIS USED TO REIMPLEMENT THE WORKER'S RULES, AND THE COPY DIVERGED —
      WHICH IS EXACTLY WHAT A SECOND IMPLEMENTATION DOES.
      It filtered ids to the candidate list and de-duplicated them, mirroring
      `PostBookAssociationWorker` + `Blog.associate_book/3` in this module's own
      code. Two of the corpus's items then certified behaviour production did
      not have — and one of them was a **live defect**: nothing de-duplicated,
      so a model naming the same book twice gave the reader two identical
      associations, while the corpus item asserting it must not scored green.
      An eval that restates the rules cannot find a disagreement with them.

      ⚖️ So this is now only what the eval's own half is: decode, and report
      the ids in order. The rules that belong to the worker are tested where
      they live — against a real database, with real `op.books` rows, in
      `post_book_association_worker_test.exs` — because that is the only place
      a duplicate or a non-existent book can actually be refused.

      ⚠️ `:unreadable` is kept distinct from `[]`: "the model said nothing we
      could read" and "the model found no books" are different facts that want
      different fixes.
  """
  @spec associate(String.t()) :: [String.t()] | :unreadable
  def associate(response) do
    case Structured.decode(response) do
      {:ok, associations} -> Enum.map(associations, & &1.book_id)
      {:error, _} -> :unreadable
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
