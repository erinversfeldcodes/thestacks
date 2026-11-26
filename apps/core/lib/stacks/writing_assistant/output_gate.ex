defmodule Stacks.WritingAssistant.OutputGate do
  @moduledoc """
      The safety gate on assistant-generated text, checked against the chunks
      that were RETRIEVED to ground it. Two independent checks:

      ## Never-verbatim (`verbatim/3`)

      The assistant may surface a work's arguments and bibliographic specifics;
      it may not reproduce the prose. A system-prompt rule alone leaks on retry
      and cannot see text already in the context window, so this is the
      mechanical backstop: a normalised longest-common-run detector of the
      response against each retrieved chunk, with the research-anchored bands

        * run >= #{50} tokens  -> blocked outright (canonical verbatim threshold);
        * #{8}..#{50} tokens   -> the gray band: blocked UNLESS the overlapping
          span is a bibliographic reference (ISBN / a long digit run / a
          publication keyword), which is allowed through;
        * < #{8} tokens        -> allowed (below the ACS floor; too short to be
          verbatim, and where genuine paraphrase lands).

      An OWNER bypass lets the author read their own text back without the gate
      firing (the recitation-false-positive lesson): grounding another reader on
      the corpus is citations and arguments only, but the author owns the prose.

      ⚠️ v1 scope. The gray band uses the STRUCTURAL allowlist only; the
      entropy/IDF distinctiveness half (which would let more innocuous overlap
      through without weakening the block on distinctive prose) and the
      original-case title detection are deferred — so the gray band errs toward
      BLOCKING, which is the safe direction for the author's prose. The
      detect->rewrite->abstain loop's rewrite arm belongs with the chat path that
      has a model to rewrite with; here the decision is detect-and-block, which
      the caller turns into an abstain.

      ## Faithfulness (`faithfulness/2`)

      Every claim the response makes should trace to a retrieved span. The v1
      check is lexical: a sentence whose content words appear in NONE of the
      spans is an ungrounded claim and is reported. This reds on a planted
      unfaithful sentence; a stricter entailment/NLI check is the refinement.
  """

  @hard_verbatim_tokens 50
  @gray_floor_tokens 8

  @doc """
      The system-prompt rule (layer (a)). One mechanism of several — it is
      necessary and not sufficient, which is why the mechanical checks exist.
  """
  @never_verbatim_rule "Never reproduce the author's prose verbatim. You may state a work's arguments and cite its bibliographic details, but render everything in your own words. If you cannot answer without quoting, abstain and say so."

  @spec never_verbatim_rule() :: String.t()
  def never_verbatim_rule, do: @never_verbatim_rule

  # A small closed-class stopword set — enough to separate "content" words from
  # grammatical glue for the overlap and faithfulness checks.
  @stopwords ~w(
    a an the this that these those and or but nor for so yet of to in on at by
    with from into over under is are was were be been being am do does did have
    has had it its it's he she they them his her their we you i me my your our
    as if then than when while where which who whom whose what how why not no
    will would can could may might must shall should
  )

  @doc """
      Check a response for verbatim reproduction of the retrieved chunks.

      Returns `:ok`, or `{:block, :verbatim, longest_run}` when a run at or above
      the hard threshold, or a non-bibliographic gray-band run, is found.

      Options: `owner_reading_own: true` bypasses the gate entirely.
  """
  @spec verbatim(String.t(), [String.t()], keyword()) ::
          :ok | {:block, :verbatim, pos_integer()}
  def verbatim(response, retrieved_chunks, opts \\ []) do
    if Keyword.get(opts, :owner_reading_own, false) do
      :ok
    else
      response_tokens = tokenize(response)

      {run, span} =
        retrieved_chunks
        |> Enum.map(&longest_shared_span(response_tokens, tokenize(&1)))
        |> Enum.max_by(fn {len, _span} -> len end, fn -> {0, []} end)

      cond do
        run >= @hard_verbatim_tokens -> {:block, :verbatim, run}
        run >= @gray_floor_tokens and not bibliographic?(span) -> {:block, :verbatim, run}
        true -> :ok
      end
    end
  end

  @doc """
      Check that every sentence of the response is grounded in some retrieved
      span. Returns `:ok` or `{:unfaithful, [sentence]}` listing the ungrounded
      sentences (those whose content words appear in none of the spans).
  """
  @spec faithfulness(String.t(), [String.t()]) :: :ok | {:unfaithful, [String.t()]}
  def faithfulness(response, retrieved_spans) do
    span_content =
      retrieved_spans
      |> Enum.flat_map(&content_words/1)
      |> MapSet.new()

    ungrounded =
      response
      |> sentences()
      |> Enum.filter(fn sentence ->
        case content_words(sentence) do
          [] -> false
          words -> not Enum.any?(words, &MapSet.member?(span_content, &1))
        end
      end)

    if ungrounded == [], do: :ok, else: {:unfaithful, ungrounded}
  end

  # --- text helpers ---

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.split(~r/\s+/, trim: true)
  end

  defp content_words(text) do
    text
    |> tokenize()
    |> Enum.reject(&(&1 in @stopwords))
  end

  defp sentences(text) do
    text
    |> String.split(~r/(?<=[.!?])\s+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # The longest contiguous run of tokens shared between `a` and `b`, returned as
  # `{length, token_list}`. Length is found by binary search on n-gram sharing
  # (monotonic: an L-gram matches => some (L-1)-gram matches); the span is one
  # matching n-gram of that length.
  defp longest_shared_span(a, b) do
    max_len = min(length(a), length(b))

    case search_run(a, b, 1, max_len, 0) do
      0 ->
        {0, []}

      len ->
        b_grams = ngrams(b, len)
        span = a |> ngrams_list(len) |> Enum.find([], &MapSet.member?(b_grams, &1))
        {len, span}
    end
  end

  defp search_run(_a, _b, lo, hi, best) when lo > hi, do: best

  defp search_run(a, b, lo, hi, best) do
    mid = div(lo + hi, 2)

    if shares_ngram?(a, b, mid) do
      search_run(a, b, mid + 1, hi, mid)
    else
      search_run(a, b, lo, mid - 1, best)
    end
  end

  defp shares_ngram?(a, b, n) do
    b_grams = ngrams(b, n)
    a |> ngrams_list(n) |> Enum.any?(&MapSet.member?(b_grams, &1))
  end

  defp ngrams(tokens, n), do: tokens |> ngrams_list(n) |> MapSet.new()

  defp ngrams_list(tokens, n) when n >= 1, do: Enum.chunk_every(tokens, n, 1, :discard)

  # A gray-band span is bibliographic (and so allowed) only on a STRONG
  # structural signal: an ISBN-shaped long digit run, or a publication keyword.
  # A bare year is deliberately NOT enough — distinctive prose often carries a
  # date, and over-allowing is the unsafe direction here.
  @biblio_keywords ~w(isbn press edition publisher vol pp ed doi)
  defp bibliographic?(span_tokens) do
    Enum.any?(span_tokens, fn token ->
      token in @biblio_keywords or isbn_like?(token)
    end)
  end

  defp isbn_like?(token) do
    digits = String.replace(token, ~r/[^0-9]/, "")

    String.length(digits) >= 10 or String.starts_with?(token, "978") or
      String.starts_with?(token, "979")
  end
end
