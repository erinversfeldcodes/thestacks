defmodule Stacks.Books.CandidateScorer do
  @moduledoc """
  Pure scoring of OL/GB title-search candidates against the ORIGINAL
  VLM-extracted signals (title, author, raw_text).

  `ISBNResolver.search_by_title/4` used to take the FIRST upstream doc
  with an ISBN. For hard images the VLM returns an enriched-but-imperfect
  title, and the upstream's first-ranked doc can be the wrong book even
  though a later doc in the SAME response is the right one. This module
  scores every non-excluded candidate so the resolver can pick the best
  instead of the first.

  ## Components (weighted sum)

    * Title token overlap (3.0) — overlap coefficient
      (`|A ∩ B| / min(|A|, |B|)`) between signal-title tokens and
      candidate title+subtitle tokens. Overlap coefficient rather than
      Jaccard because the VLM title is often longer than the catalogue
      title and Jaccard over-penalises that.
    * Subtitle evidence (2.0) — fraction of signal-title tokens found in
      the candidate's subtitle. Disambiguates VLM titles that absorb
      subtitle keywords. NOTE: Open Library search docs return
      `subtitle: nil` in practice (verified against the live API), so
      this component fires almost exclusively on Google Books
      candidates; subject evidence covers the OL side.
    * Subject evidence (1.0 per distinct hit, capped at 3) — distinct
      signal-title tokens found as substrings of the normalised, joined
      candidate subjects list. Substring containment (like raw_text) so
      "internment" hits "Internment Camp (Crystal City, Tex.)". The cap
      prevents subject-spam inflation. This is the load-bearing
      disambiguator for OL candidates, whose docs carry rich subjects
      but no subtitle.
    * raw_text keyword hits (1.5) — fraction of raw_text tokens
      (length >= 3, OCR fragments like "F DRS" collapsed to "fdrs")
      found as substrings of the normalised candidate
      title+subtitle+subjects.
    * Author surname match (1.0) — positive-evidence-only: the VLM
      frequently invents authors, so a match is a bonus and a mismatch
      is never a penalty.
    * Exact-title bonus (0.5) — full normalised equality between signal
      title and candidate title; protects easy cases from regressing.

  ## Crystal City sanity check (real OL data, subtitle: nil throughout)

  Signals: title "The Crystal City: The Tragedy of America's First
  Internment Camp" (tokens {crystal city tragedy americas first
  internment camp}, 7), author "Doris Akers" (invented), raw_text
  "THE CRYSTAL CI IT IS ABOUT F DRS" (tokens {crystal about fdrs}).

  Card candidate ("The Crystal City", subtitle nil, subjects
  ["Alvin Maker (Fictitious character)", "Fiction", "Magic",
  "Frontier and pioneer life", "Fiction, fantasy, general"]):
  overlap 2/2 → 3.0; subtitle 0; subjects 0 hits → 0.0;
  raw_text 1/3 ("crystal") → 0.5; total 3.5.

  Russell candidate ("The train to Crystal City", subtitle nil,
  subjects ["Concentration camps", "German Americans",
  "World War, 1939-1945", "Crystal City Internment Camp (Crystal
  City, Tex.)", "Evacuation of civilians"]):
  overlap 2/3 ({crystal city} of {train crystal city}) → 2.0;
  subtitle 0; subjects hits {crystal, city, internment, camp} = 4,
  capped at 3 → 3.0; raw_text 1/3 ("crystal") → 0.5; total 5.5.

  Russell (5.5) outscores Card (3.5) by 2.0. Tarantino and Etchemendy
  ("The Crystal City"/"The crystal city", no subject hits) also score
  3.5 and cannot win. Verified in `candidate_scorer_test.exs`.

  ## Derivative-title penalty

  Production failure (Klara and the Sun, chore/enable-pipelines): GB
  returns a "Study Guide: Klara and the Sun by Kazuo Ishiguro"
  derivative that OUTSCORES the real work — the derivative's title
  absorbs the author tokens (raw_text hits 4/4 vs the real work's 2/4)
  and GB mislabels the derivative's author as "Kazuo Ishiguro", so it
  also collects the author bonus AND the floor waiver.

  Fix: subtract `derivative_penalty` (default 2.0) when the CANDIDATE
  title contains a derivative marker token (study, guide, summary,
  analysis, workbook, sparknotes) but the SIGNAL title does not. If the
  user actually photographed a study guide, the VLM title carries the
  marker too and no penalty applies. Sized 2.0: the Klara derivative
  led the real work by 0.25, and marker-bearing derivatives typically
  collect ≤ 1.5 spurious raw_text/author advantage; 2.0 clears both
  with margin while staying too small to sink a genuinely-matching
  title (overlap 3.0 + exact 0.5) below a same-work alternative.
  Verified offline via `mix eval.resolver` (klara_study_guide entry).

  ## Tuning

  All weights and the plausibility floor are overridable per call (see
  `score/3` and `pick_best/3`), which is how the offline eval harness
  (`mix eval.resolver`, corpus in `priv/eval/corpus.exs`) runs one-flag
  tuning experiments against recorded production cases. Change a
  default here only with a corpus run to back it up.
  """

  @default_weights %{
    title_overlap: 3.0,
    subtitle: 2.0,
    subject_hit: 1.0,
    raw_text: 1.5,
    author: 1.0,
    exact_title: 0.5,
    derivative_penalty: 2.0
  }

  @subject_hit_cap 3

  @default_floor 2.5

  @derivative_tokens ~w(study guide summary analysis workbook sparknotes)

  @stopwords ~w(the a an of to and in on for)

  @doc """
  Scores a candidate's metadata against the original VLM signals.

  `candidate_meta` is the OL/GB metadata map (`:title`, `:subtitle`,
  `:author`, `:subjects` — a list of strings). `signals` is
  `%{title: ..., author: ..., raw_text: ...}` as extracted by the
  vision model. All fields are nil-safe.

  Returns the weighted sum; higher is better. No minimum threshold —
  `pick_best/3` applies the plausibility floor.

  ## Options

    * `:weights` — keyword list or map overriding any of the default
      component weights (`:title_overlap`, `:subtitle`, `:subject_hit`,
      `:raw_text`, `:author`, `:exact_title`, `:derivative_penalty`).
      Used by `mix eval.resolver` for offline tuning experiments.
  """
  @spec score(candidate_meta :: map(), signals :: map(), opts :: keyword()) :: float()
  def score(candidate_meta, signals, opts \\ []) do
    w = weights(opts)
    signal_title_tokens = tokens(signals[:title])
    title_tokens = tokens(candidate_meta[:title])
    subtitle_tokens = tokens(candidate_meta[:subtitle])
    candidate_tokens = MapSet.union(title_tokens, subtitle_tokens)
    subjects_text = subjects_text(candidate_meta[:subjects])
    candidate_text = candidate_text(candidate_meta, subjects_text)

    title_overlap_score(signal_title_tokens, candidate_tokens, w.title_overlap) +
      subtitle_score(signal_title_tokens, subtitle_tokens, w.subtitle) +
      subject_score(signal_title_tokens, subjects_text, w.subject_hit) +
      raw_text_score(signals[:raw_text], candidate_text, w.raw_text) +
      author_score(signals[:author], candidate_meta[:author], w.author) +
      exact_title_score(signals[:title], candidate_meta[:title], w.exact_title) +
      derivative_penalty(signal_title_tokens, title_tokens, w.derivative_penalty)
  end

  @doc """
  Picks the highest-scoring candidate and applies the plausibility
  floor. This is the SINGLE seam shared by the production resolver
  (`ISBNResolver.pick_best_candidate/3`) and the offline eval harness
  (`mix eval.resolver`) — both must exercise identical pick logic.

  `candidates` is a list of `{isbn, candidate_meta}` tuples. Scoring is
  `score/3` against `signals`; `Enum.sort_by/3` is stable, so on a
  score tie the caller's ordering (the provider's own ranking) decides
  — exactly the old first-doc-wins behaviour.

  Returns:

    * `:empty` — no candidates
    * `{:ok, {score, isbn, meta}, runner_up}` — best candidate is
      plausible (`score >= floor`, or author corroboration waives the
      floor). `runner_up` is the second-best `{score, isbn, meta}` or
      `nil`.
    * `{:floored, {score, isbn, meta}, runner_up}` — best candidate is
      below the floor with no author corroboration; treat as no match.

  ## Options

    * `:floor` — plausibility floor (default `#{@default_floor}`, see
      `default_floor/0`)
    * `:weights` — see `score/3`
  """
  @spec pick_best([{String.t(), map()}], map(), keyword()) ::
          :empty
          | {:ok, {float(), String.t(), map()}, {float(), String.t(), map()} | nil}
          | {:floored, {float(), String.t(), map()}, {float(), String.t(), map()} | nil}
  def pick_best(candidates, signals, opts \\ [])

  def pick_best([], _signals, _opts), do: :empty

  def pick_best(candidates, signals, opts) do
    floor = Keyword.get(opts, :floor, @default_floor)

    [{best_score, _isbn, best_meta} = best | rest] =
      candidates
      |> Enum.map(fn {isbn, meta} -> {score(meta, signals, opts), isbn, meta} end)
      |> Enum.sort_by(&elem(&1, 0), :desc)

    runner_up = List.first(rest)

    if best_score >= floor or author_match?(best_meta, signals) do
      {:ok, best, runner_up}
    else
      {:floored, best, runner_up}
    end
  end

  @doc "The default plausibility floor used by `pick_best/3`."
  @spec default_floor() :: float()
  def default_floor, do: @default_floor

  @doc "The default component weights used by `score/3`."
  @spec default_weights() :: %{atom() => float()}
  def default_weights, do: @default_weights

  @doc """
  True when the candidate has author corroboration — the same
  positive-evidence-only surname check that feeds the author component
  of `score/2` (a match contributes, a mismatch never penalises).

  Exposed so the resolver's plausibility floor can waive itself for
  author-corroborated candidates: a scored author match at any total
  score is strong evidence the pick is not a garbage fuzzy match.
  """
  @spec author_match?(candidate_meta :: map(), signals :: map()) :: boolean()
  def author_match?(candidate_meta, signals) do
    surname_match?(signals[:author], candidate_meta[:author])
  end

  defp weights(opts) do
    Map.merge(@default_weights, Map.new(Keyword.get(opts, :weights, [])))
  end

  defp title_overlap_score(signal_tokens, candidate_tokens, weight) do
    min_size = min(MapSet.size(signal_tokens), MapSet.size(candidate_tokens))

    if min_size == 0 do
      0.0
    else
      hits = MapSet.size(MapSet.intersection(signal_tokens, candidate_tokens))
      weight * hits / min_size
    end
  end

  defp subtitle_score(signal_tokens, subtitle_tokens, weight) do
    if MapSet.size(signal_tokens) == 0 or MapSet.size(subtitle_tokens) == 0 do
      0.0
    else
      hits = MapSet.size(MapSet.intersection(signal_tokens, subtitle_tokens))
      weight * hits / MapSet.size(signal_tokens)
    end
  end

  defp subject_score(signal_tokens, subjects_text, weight) do
    if subjects_text == "" do
      0.0
    else
      hits = Enum.count(signal_tokens, &String.contains?(subjects_text, &1))
      weight * min(hits, @subject_hit_cap)
    end
  end

  defp raw_text_score(raw_text, candidate_text, weight) do
    raw_tokens = raw_text_tokens(raw_text)

    if raw_tokens == [] or candidate_text == "" do
      0.0
    else
      hits = Enum.count(raw_tokens, &String.contains?(candidate_text, &1))
      weight * hits / length(raw_tokens)
    end
  end

  defp author_score(signal_author, candidate_author, weight) do
    if surname_match?(signal_author, candidate_author), do: weight, else: 0.0
  end

  defp surname_match?(signal_author, candidate_author) do
    surname = signal_author |> normalize() |> String.split() |> List.last()
    surname != nil and MapSet.member?(tokens(candidate_author), surname)
  end

  defp exact_title_score(signal_title, candidate_title, weight) do
    normalised = normalize(signal_title)

    if normalised != "" and normalised == normalize(candidate_title) do
      weight
    else
      0.0
    end
  end

  defp derivative_penalty(signal_title_tokens, candidate_title_tokens, weight) do
    candidate_derivative? =
      Enum.any?(@derivative_tokens, &MapSet.member?(candidate_title_tokens, &1))

    signal_derivative? = Enum.any?(@derivative_tokens, &MapSet.member?(signal_title_tokens, &1))

    if candidate_derivative? and not signal_derivative?, do: -weight, else: 0.0
  end

  defp normalize(nil), do: ""

  defp normalize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/['’]/u, "")
    |> String.replace(~r/[^[:alnum:]\s]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp tokens(text) do
    text
    |> normalize()
    |> String.split()
    |> Enum.reject(&(&1 in @stopwords or String.length(&1) < 2))
    |> MapSet.new()
  end

  defp candidate_text(candidate_meta, subjects_text) do
    [normalize(candidate_meta[:title]), normalize(candidate_meta[:subtitle]), subjects_text]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp subjects_text(subjects) when is_list(subjects) do
    subjects
    |> Enum.filter(&is_binary/1)
    |> Enum.map_join(" ", &normalize/1)
    |> String.trim()
  end

  defp subjects_text(_), do: ""

  defp raw_text_tokens(nil), do: []

  defp raw_text_tokens(text) when is_binary(text) do
    text
    |> normalize()
    |> collapse_fragments()
    |> String.split()
    |> Enum.reject(&(&1 in @stopwords or String.length(&1) < 3))
    |> Enum.uniq()
  end

  defp collapse_fragments(text) do
    Regex.replace(~r/\b(\w)\s+(?=\w)/u, text, "\\1")
  end
end
