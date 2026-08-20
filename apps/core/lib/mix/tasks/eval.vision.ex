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

  defp score_image(%{path: path} = item) do
    full = Path.join(root(), path)

    case File.read(full) do
      {:error, reason} ->
        Map.merge(item, %{ok: false, detail: "unreadable (#{inspect(reason)})"})

      {:ok, bytes} ->
        b64 = Base.encode64(bytes)

        case analyze(b64) do
          {:error, reason} ->
            Map.merge(item, %{ok: false, detail: "call failed: #{inspect(reason)}"})

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

  # The production seam exactly: `Stacks.Moderation` posts `%{image: b64}` to
  # /analyze and reads a CLASSIFICATION_RESULT_* enum plus a `books` list, each
  # entry carrying `potential_isbns`. One call answers both questions this corpus
  # asks. Scoring against a different endpoint or payload shape would measure
  # something no reader ever exercises — an earlier draft called /classify with
  # `%{image_b64: ...}` and got `malformed_request` from a perfectly healthy
  # service, which reads as a model failure and is not one.
  #
  # AMBIGUOUS counts as "not a book": the upload path cannot shelve an ambiguous
  # result either, so scoring it as a hit would flatter the model against what a
  # reader actually gets.
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

  defp gate(results, record?) do
    passed = Enum.count(results, & &1.ok)
    total = length(results)
    Mix.shell().info("\nscore: #{passed}/#{total}")

    baseline_file = Path.join(Application.app_dir(:core), @baseline_path)
    baseline = read_baseline(baseline_file)

    cond do
      record? ->
        write_baseline(baseline_file, passed, total)
        Mix.shell().info("recorded #{passed}/#{total} as the new baseline")

      is_nil(baseline) ->
        Mix.shell().info(
          "no baseline recorded yet — run `mix eval.vision --record` to pin this score. " <>
            "Nothing is being gated until you do."
        )

      passed < baseline ->
        Mix.raise(
          "eval.vision: REGRESSION — scored #{passed}/#{total}, baseline is #{baseline}. " <>
            "Something the vision service used to get right it now gets wrong."
        )

      true ->
        Mix.shell().info("no regression (baseline #{baseline})")
    end
  end

  defp read_baseline(file) do
    with {:ok, body} <- File.read(file),
         {:ok, %{"passed" => passed}} <- Jason.decode(body) do
      passed
    else
      _ -> nil
    end
  end

  defp write_baseline(file, passed, total) do
    File.mkdir_p!(Path.dirname(file))

    File.write!(
      file,
      Jason.encode!(%{passed: passed, total: total, recorded_at: DateTime.utc_now()},
        pretty: true
      )
    )
  end
end
