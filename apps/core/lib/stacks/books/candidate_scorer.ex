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
  """

  @w_title_overlap 3.0
  @w_subtitle 2.0
  @w_subject_hit 1.0
  @subject_hit_cap 3
  @w_raw_text 1.5
  @w_author 1.0
  @w_exact_title 0.5

  @stopwords ~w(the a an of to and in on for)

  @doc """
  Scores a candidate's metadata against the original VLM signals.

  `candidate_meta` is the OL/GB metadata map (`:title`, `:subtitle`,
  `:author`, `:subjects` — a list of strings). `signals` is
  `%{title: ..., author: ..., raw_text: ...}` as extracted by the
  vision model. All fields are nil-safe.

  Returns the weighted sum; higher is better. No minimum threshold —
  the caller takes the max-scoring candidate.
  """
  @spec score(candidate_meta :: map(), signals :: map()) :: float()
  def score(candidate_meta, signals) do
    signal_title_tokens = tokens(signals[:title])
    title_tokens = tokens(candidate_meta[:title])
    subtitle_tokens = tokens(candidate_meta[:subtitle])
    candidate_tokens = MapSet.union(title_tokens, subtitle_tokens)
    subjects_text = subjects_text(candidate_meta[:subjects])
    candidate_text = candidate_text(candidate_meta, subjects_text)

    title_overlap_score(signal_title_tokens, candidate_tokens) +
      subtitle_score(signal_title_tokens, subtitle_tokens) +
      subject_score(signal_title_tokens, subjects_text) +
      raw_text_score(signals[:raw_text], candidate_text) +
      author_score(signals[:author], candidate_meta[:author]) +
      exact_title_score(signals[:title], candidate_meta[:title])
  end

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
    author_score(signals[:author], candidate_meta[:author]) > 0.0
  end

  # --- components --------------------------------------------------------

  defp title_overlap_score(signal_tokens, candidate_tokens) do
    min_size = min(MapSet.size(signal_tokens), MapSet.size(candidate_tokens))

    if min_size == 0 do
      0.0
    else
      hits = MapSet.size(MapSet.intersection(signal_tokens, candidate_tokens))
      @w_title_overlap * hits / min_size
    end
  end

  defp subtitle_score(signal_tokens, subtitle_tokens) do
    if MapSet.size(signal_tokens) == 0 or MapSet.size(subtitle_tokens) == 0 do
      0.0
    else
      hits = MapSet.size(MapSet.intersection(signal_tokens, subtitle_tokens))
      @w_subtitle * hits / MapSet.size(signal_tokens)
    end
  end

  # Substring containment against the joined subjects text so a signal
  # token like "internment" hits "Crystal City Internment Camp
  # (Crystal City, Tex.)". Per-distinct-hit weight, capped at
  # @subject_hit_cap so candidates with sprawling subject lists can't
  # inflate their score.
  defp subject_score(signal_tokens, subjects_text) do
    if subjects_text == "" do
      0.0
    else
      hits = Enum.count(signal_tokens, &String.contains?(subjects_text, &1))
      @w_subject_hit * min(hits, @subject_hit_cap)
    end
  end

  # Substring containment (not token equality) so an OCR fragment like
  # "fdrs" still hits a candidate subtitle containing "FDR's" (whose
  # normalised form is "fdrs secret ...").
  defp raw_text_score(raw_text, candidate_text) do
    raw_tokens = raw_text_tokens(raw_text)

    if raw_tokens == [] or candidate_text == "" do
      0.0
    else
      hits = Enum.count(raw_tokens, &String.contains?(candidate_text, &1))
      @w_raw_text * hits / length(raw_tokens)
    end
  end

  # Positive-evidence-only: bonus when the signal author's surname
  # appears among the candidate's author tokens; no penalty otherwise
  # (the VLM frequently invents authors).
  defp author_score(signal_author, candidate_author) do
    surname = signal_author |> normalize() |> String.split() |> List.last()

    if surname != nil and MapSet.member?(tokens(candidate_author), surname) do
      @w_author
    else
      0.0
    end
  end

  defp exact_title_score(signal_title, candidate_title) do
    normalised = normalize(signal_title)

    if normalised != "" and normalised == normalize(candidate_title) do
      @w_exact_title
    else
      0.0
    end
  end

  # --- normalisation ------------------------------------------------------

  # Downcase, drop apostrophes (so "FDR's" → "fdrs", "America's" →
  # "americas"), turn remaining punctuation into spaces, collapse runs.
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

  # raw_text matches against title+subtitle+subjects: OL search docs
  # carry no subtitle, so OCR keywords often only corroborate via the
  # subjects list.
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

  # Join single-character fragments to the following token so
  # OCR-fractured words still match: "f drs" → "fdrs". Applied only to
  # raw_text (titles are not OCR-fractured the same way).
  #
  # ORDERING INVARIANT: this must run AFTER `normalize/1` has stripped
  # apostrophes. Possessives like "TRAMP'S" normalise to the single
  # token "tramps"; if the apostrophe instead became a space, the
  # orphan "s" would be glued onto the NEXT word here ("s crystal" →
  # "scrystal") and corrupt the tokens — the production "scrystal" bug
  # in the resolver's parallel raw_text normalisation.
  defp collapse_fragments(text) do
    Regex.replace(~r/\b(\w)\s+(?=\w)/u, text, "\\1")
  end
end
