defmodule Mix.Tasks.Eval.Cascade do
  @shortdoc "Scores the FULL identification cascade against the corpus and the 7B end-state reference"

  @moduledoc """
      Drives `Stacks.Moderation.run_pipeline/1` — the cascade core actually
      runs in production: CPU tiers, catalogue resolution, the ISBN gate, and
      the GPU only on a miss — over every corpus image, and scores the
      RESOLVED outcome. `mix eval.vision` scores the sidecar seam; this scores
      the layer above it, which the first live drive proved can be wrong while
      the sidecar eval stays green (a partial OCR title resolved three
      different wrong-but-real books while the GPU slept).

          MIX_ENV=test VISION_SERVICE_URL=https://… mix eval.cascade
          … --corpus path --stratum name       # the eval.vision selectors

      ⛔ TEST ENV ON PURPOSE: resolution STORES books, and the SQL sandbox is
      the only machinery here that lets a run write 122 catalogue rows and
      leave no trace. The task checks out a sandbox owner in shared mode and
      never commits. It swaps the mock roster back to the REAL clients for
      exactly the two seams the cascade needs live (the vision sidecar, the
      OL/GB catalogue) — everything else stays mocked, which is also what
      keeps the run from touching storage or email.

      ## The gate: the END-STATE bar, deliberately model-transcendent

      The per-stratum comparison is against
      `priv/eval/vision_baseline_7b_reference.json` — the two-baseline
      protocol's end-state bar. It is NOT model-keyed on purpose, where
      `eval.vision`'s drop-in gate is: the protocol's whole point is that the
      cascade answers to the 7B reference's numbers ACROSS the model swap,
      with the ruling's named concessions tolerated until their expiry. A
      stratum below its reference score is reported; `EVAL_CASCADE_STRICT=1`
      makes any such stratum fail the run (the concessions' expiry switch).
  """

  use Mix.Task

  alias Ecto.Adapters.SQL.Sandbox
  alias Mix.Tasks.Eval.Vision, as: VisionEval

  @switches [corpus: :string, stratum: :string]
  @reference_path "priv/eval/vision_baseline_7b_reference.json"

  # The ruling's named concessions: tolerated below the reference until the
  # CPU-first path and the spine review land, then EVAL_CASCADE_STRICT=1.
  @conceded_strata ~w(illegible hostile_barcode book_adjacent)

  def run(argv) do
    Mix.Task.run("app.start")
    {cli, _, _} = OptionParser.parse(argv, strict: @switches)

    if Mix.env() != :test do
      Mix.raise(
        "eval.cascade: MIX_ENV=test required — resolution stores books, and the " <>
          "SQL sandbox is what lets this run leave no rows behind."
      )
    end

    case System.get_env("VISION_SERVICE_URL") do
      url when is_binary(url) and url != "" ->
        Application.put_env(:core, :vision_service_url, url)

      _ ->
        msg =
          "eval.cascade: SKIPPED — VISION_SERVICE_URL is not set, so there is no " <>
            "deployed cascade to score. This is not a pass."

        if System.get_env("EVAL_CASCADE_REQUIRED") == "1",
          do: Mix.raise(msg <> " EVAL_CASCADE_REQUIRED=1 is set, so a skip is a failure."),
          else: Mix.shell().info(msg)

        exit(:normal)
    end

    point_roster_at_reality()
    checkout_sandbox()

    corpus =
      cli
      |> Keyword.get(:corpus)
      |> VisionEval.load_corpus()
      |> VisionEval.only_stratum(Keyword.get(cli, :stratum))

    collector = start_collector()
    results = Enum.map(corpus, &score_case(&1, collector))

    report(results)
    gate(results)
  end

  # ⚖️ Exactly the two seams the cascade needs live. The roster memoranda in
  # test.exs stay authoritative for every suite; this narrow swap exists only
  # inside this task's run.
  defp point_roster_at_reality do
    Application.put_env(:core, :vision_client, Stacks.AI.Client)
    Application.put_env(:core, :isbn_http_client, Stacks.Books.HttpClient)
    # The cascade order under test is the PRODUCTION order.
    Application.put_env(:core, :cpu_first_identification, true)

    # test.exs pins a dummy HMAC secret; the DEPLOYED sidecar validates the
    # real one, so the run must sign with it or every call is a 401 that
    # would read as a cascade failure.
    case System.get_env("VISION_HMAC_SECRET") do
      secret when is_binary(secret) and secret != "" ->
        Application.put_env(:core, :vision_hmac_secret, secret)

      _ ->
        Mix.raise(
          "eval.cascade: VISION_HMAC_SECRET is not set — the deployed sidecar " <>
            "would refuse every call and the refusals would score as misses."
        )
    end
  end

  defp checkout_sandbox do
    # ⚠️ :infinity, because the default ownership_timeout (2 minutes) is
    # shorter than one cold GPU call plus a retry — the first run lost its
    # ownership before the first write and the sandbox reported a crashed
    # owner. An eval holds this checkout for the whole corpus by design.
    :ok = Sandbox.checkout(Core.Repo, ownership_timeout: :infinity)
    Sandbox.mode(Core.Repo, {:shared, self()})
  end

  # Counts vision calls per case by listening where the client already emits;
  # cpu-resolved = the pipeline answered without any VLM-tier response.
  defp start_collector do
    parent = self()
    ref = make_ref()

    :telemetry.attach(
      {__MODULE__, ref},
      [:stacks, :vision, :request, :stop],
      fn _e, _m, meta, _c -> send(parent, {:vision_call, Map.get(meta, :tier)}) end,
      nil
    )

    ref
  end

  defp drain_calls(acc) do
    receive do
      {:vision_call, tier} -> drain_calls([tier | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp score_case(%{path: path} = item, _collector) do
    full = Path.join(VisionEval.root(), path)

    case File.read(full) do
      {:error, reason} ->
        Map.merge(item, %{
          ok: false,
          unscored: true,
          via: :none,
          detail: "unreadable fixture (#{inspect(reason)}) — the corpus, not the cascade"
        })

      {:ok, bytes} ->
        _ = drain_calls([])
        # ⚠️ 122 uncached serial cases melt the OL fuse mid-run (5 cases came
        # back :resolver_unavailable on the first full run). An offline
        # harness can afford manners: a breath between cases, and fresh fuses
        # so one throttled burst does not poison the cases behind it.
        :fuse.reset(:open_library_fuse)
        :fuse.reset(:google_books_fuse)
        Process.sleep(500)
        started = System.monotonic_time(:millisecond)

        outcome =
          Stacks.Moderation.run_pipeline(%{
            image_b64: Base.encode64(bytes),
            user_id: Ecto.UUID.generate(),
            image_id: Ecto.UUID.generate()
          })

        # ⚠️ One retry on TRANSPORT only, after a cooldown: a throttled OL
        # window is not an answer about the cascade, and the first two full
        # runs each lost 5–6 cases to :resolver_unavailable despite pacing.
        # Answers — right or wrong — are never retried.
        outcome =
          case judge(item, outcome) do
            %{unscored: true} ->
              Process.sleep(15_000)
              :fuse.reset(:open_library_fuse)
              :fuse.reset(:google_books_fuse)
              _ = drain_calls([])

              Stacks.Moderation.run_pipeline(%{
                image_b64: Base.encode64(bytes),
                user_id: Ecto.UUID.generate(),
                image_id: Ecto.UUID.generate()
              })

            _scored ->
              outcome
          end

        wall_ms = System.monotonic_time(:millisecond) - started
        tiers = drain_calls([])
        via = resolved_via(outcome, tiers)
        scored = judge(item, outcome)

        Mix.shell().info(
          "#{if scored.ok, do: "PASS ", else: "FAIL "}#{item.name} #{wall_ms}ms via=#{via} #{scored.detail}"
        )

        item
        |> Map.merge(scored)
        |> Map.merge(%{via: via, wall_ms: wall_ms})
    end
  end

  # ⚠️ Transport-shaped failures are UNSCORED (the call never became an
  # answer); :isbn_not_found and :not_a_book are ANSWERS and score.
  defp judge(%{expect_book: false}, {:error, :not_a_book}),
    do: %{ok: true, detail: "correctly not a book"}

  defp judge(%{expect_book: false}, {:ok, %{resolved: books}}),
    do: %{ok: false, detail: "resolved #{length(books)} book(s) for a non-book"}

  defp judge(%{expect_book: false}, {:error, :isbn_not_found}),
    do: %{ok: true, detail: "no identification claimed (isbn_not_found)"}

  defp judge(item, {:ok, %{resolved: books}}) do
    isbns = Enum.flat_map(books, fn b -> Enum.map(b.editions, & &1.isbn) end)
    titles = Enum.map(books, & &1.title)
    isbn_ok = is_nil(item.expect_isbn) or item.expect_isbn in isbns
    title_ok = VisionEval.identity_ok?(Map.get(item, :expect_title), titles)

    %{
      ok: isbn_ok and title_ok,
      detail:
        "resolved=#{inspect(Enum.take(titles, 2))} isbns=#{inspect(Enum.take(isbns, 3))}" <>
          " isbn_ok=#{isbn_ok} title_ok=#{title_ok}"
    }
  end

  defp judge(%{expect_book: true}, {:error, :not_a_book}),
    do: %{ok: false, detail: "called a real book not_a_book"}

  defp judge(%{expect_book: true}, {:error, :isbn_not_found}),
    do: %{ok: false, detail: "no identification (isbn_not_found)"}

  defp judge(_item, {:error, reason}),
    do: %{ok: false, unscored: true, detail: "transport: #{inspect(reason)}"}

  defp resolved_via({:error, _}, _tiers), do: :none

  defp resolved_via({:ok, _}, tiers) do
    cond do
      Enum.any?(tiers, &(&1 in ["ANALYSIS_TIER_VLM_EXTRACT", "ANALYSIS_TIER_VLM_CLASSIFY"])) ->
        :gpu

      Enum.any?(tiers, &(&1 == "ANALYSIS_TIER_BARCODE")) ->
        :barcode

      true ->
        :cpu_title
    end
  end

  defp report(results) do
    scored = Enum.reject(results, &Map.get(&1, :unscored, false))
    passed = Enum.count(scored, & &1.ok)

    Mix.shell().info("\ncascade score: #{passed}/#{length(scored)} (#{length(results)} cases)")

    Mix.shell().info("\nresolution route (the wake-frequency answer):")

    results
    |> Enum.frequencies_by(&Map.get(&1, :via, :none))
    |> Enum.sort()
    |> Enum.each(fn {via, n} -> Mix.shell().info("  #{via}: #{n}") end)

    Mix.shell().info("\nby stratum:")

    results
    |> Enum.group_by(& &1.stratum)
    |> Enum.sort()
    |> Enum.each(fn {stratum, rows} ->
      ok = Enum.count(rows, & &1.ok)
      Mix.shell().info("  #{stratum}  #{ok}/#{length(rows)}")
    end)
  end

  defp gate(results) do
    unscored = Enum.count(results, &Map.get(&1, :unscored, false))

    if unscored > 0 do
      Mix.raise(
        "eval.cascade: INCOMPLETE — #{unscored} case(s) could not be scored " <>
          "(transport, not an answer). No verdict on a partial run."
      )
    end

    below = strata_below_reference(results, read_reference())
    {conceded, hard} = Enum.split_with(below, fn {s, _, _, _} -> s in @conceded_strata end)

    Enum.each(conceded, fn {s, ok, ref, total} ->
      Mix.shell().info(
        "CONCEDED #{s}: #{ok}/#{total} vs reference #{ref}/#{total} — tolerated " <>
          "until the concession expires (EVAL_CASCADE_STRICT=1)"
      )
    end)

    verdict_on(hard, conceded)
  end

  defp strata_below_reference(results, reference) do
    results
    |> Enum.group_by(&to_string(&1.stratum))
    |> Enum.flat_map(fn {stratum, rows} ->
      ok = Enum.count(rows, & &1.ok)

      case reference["strata"][stratum] do
        %{"passed" => ref_passed, "total" => ref_total}
        when length(rows) == ref_total and ok < ref_passed ->
          [{stratum, ok, ref_passed, ref_total}]

        _ ->
          []
      end
    end)
  end

  defp verdict_on(hard, conceded) do
    strict? = System.get_env("EVAL_CASCADE_STRICT") == "1"

    cond do
      hard != [] ->
        lines =
          Enum.map_join(hard, "\n  ", fn {s, ok, ref, t} -> "#{s}: #{ok}/#{t} vs #{ref}/#{t}" end)

        Mix.raise("eval.cascade: BELOW THE END-STATE REFERENCE on:\n  #{lines}")

      strict? and conceded != [] ->
        Mix.raise("eval.cascade: conceded strata remain below the reference and STRICT is set")

      true ->
        Mix.shell().info("\nend-state bar: no non-conceded stratum below the 7B reference")
    end
  end

  defp read_reference do
    path = Path.join(Application.app_dir(:core), @reference_path)

    case File.read(path) do
      {:ok, body} ->
        Jason.decode!(body)

      {:error, reason} ->
        Mix.raise("eval.cascade: cannot read the reference (#{inspect(reason)})")
    end
  end
end
