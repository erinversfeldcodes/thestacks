defmodule Stacks.Books.CandidateScorer do
  @moduledoc """
  Pure scoring of OL/GB title-search candidates against the original
  VLM-extracted signals (title, author, raw_text), so the resolver picks the
  BEST candidate instead of the upstream's first-ranked doc (which for hard
  images is often the wrong book while the right one sits later in the same
  response).

  Weighted components: title token overlap 3.0 (overlap coefficient, not
  Jaccard — the VLM title is often longer than the catalogue's), subtitle
  evidence 2.0 (GB-only in practice; OL search docs return `subtitle: nil`),
  subject hits, raw-text corroboration, author match, exact-title bonus, and
  a derivative penalty (summaries/workbooks/study guides score against the
  original). Pure functions — no HTTP, no Repo — so `mix eval.resolver` can
  tune weights offline.
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
  Scores one candidate's OL/GB metadata (`:title`, `:subtitle`, `:author`,
  `:subjects`) against the VLM signals (`%{title, author, raw_text}`);
  nil-safe; higher is better. No threshold here — `pick_best/3` applies the
  plausibility floor. `:weights` overrides component weights (used by
  `mix eval.resolver` for offline tuning).
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
  Picks the highest-scoring `{isbn, meta}` candidate and applies the
  plausibility floor. The SINGLE seam shared by the production resolver and
  `mix eval.resolver` — both must exercise identical pick logic. Sort is
  stable, so a score tie preserves the provider's own ranking (old
  first-doc-wins behaviour). Returns `:empty`, `{:ok, best, runner_up}`
  (plausible: `score >= floor`, or author corroboration waives it), or
  `{:floored, best, runner_up}` (treat as no match). Options: `:floor`
  (default `#{@default_floor}`), `:weights`.
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
