defmodule Stacks.Enrichment.StoreMatcher do
  @moduledoc """
  Matches a bookshop's product titles to editions we hold, for the shops that carry
  no ISBN on any product.

  ## Why this exists

  Two targets have no ISBN anywhere: Ike's Books (0 of 50 sampled products) and Love
  Books (0 of 30). No amount of enumeration can map an ISBN to a product there, so
  the only remaining path is matching the shop's title against ours — and that has to
  happen here, because the scraper service knows the shop while only we know our
  catalogue.

  ## Why it reuses CandidateScorer

  `Stacks.Books.CandidateScorer` already does exactly this job for the ISBN resolver:
  weighted title/subtitle/author overlap with a plausibility floor that a fuzzy match
  must clear, and a derivative penalty that keeps "study guide to X" from matching X.
  It is unit-tested and has an offline eval harness (`mix eval.resolver`).

  Building a second matcher would mean a second set of weights to tune, a second
  floor to calibrate, and two things to keep honest. This passes the shop's listing
  as the *candidate* and our edition as the *signal*, which is the same shape the
  resolver uses with the roles swapped.

  ## Where the reuse stops, and why

  The scorer alone is **not sufficient here**, and it took measuring to see it. Its
  title signal is an *overlap coefficient* — intersection over the smaller token set —
  so any subset relationship scores full marks. Measured against a "The Name of the
  Rose" signal:

      3.5  exact title
      3.0  "The Island" vs "The Island of the Day Before"   ← subset, scores as well
      3.0  "Sapiens" vs "Sapiens: A Brief History…"          ← subset, also full marks
      1.0  "A Study Guide to The Name of the Rose"           ← derivative penalty works
      0.0  unrelated title

  That behaviour is *right* for the resolver, which wants "Sapiens" to match its
  subtitled edition. It is wrong here: on a shop's shelf, extra words often mean a
  different volume, a boxed set, or a companion. Only 0.5 separates an exact match from
  a partial one, which is too little to bet a price and a buy-link on.

  So this adds a **token-symmetry requirement** (Jaccard, not overlap) on top of the
  score. Jaccard punishes asymmetry: 1.0 for an exact match, 0.33 for
  "The Island" vs "The Island of the Day Before", 0.17 for "Sapiens" vs its subtitled
  form. Requiring symmetry rejects both partials.

  That does mean refusing some legitimate matches — a shop listing "Sapiens: A Brief
  History of Humankind" for our "Sapiens" will not match. That is the intended trade:
  for a shop with no ISBNs, no price is honest and someone else's price is not.

  ## Why the floor and margin

  A wrong ISBN match shows a reader the wrong metadata. A wrong *store* match shows
  them a price for a different book and links them to buy it. So the best candidate
  must also beat the runner-up by a margin — two listings a whisker apart means we
  cannot tell them apart, and guessing attaches a real price to the wrong book.
  """

  require Logger

  alias Stacks.Books.CandidateScorer

  # Above CandidateScorer's default of 2.5, and set from measurement rather than taste:
  # a derivative ("A Study Guide to X") scores 1.0 and an unrelated title 0.0, while
  # any genuine title relationship scores 3.0 or more.
  @floor 3.0

  # How far ahead of the runner-up the winner must be. Measured: an exact match scores
  # 3.5 and a derivative 1.0, so a real winner clears this comfortably while two
  # equally-plausible listings do not.
  @min_margin 1.0

  # Minimum token-set symmetry (Jaccard) between our title and the shop's.
  #
  # This is the part the score cannot do. 0.6 accepts exact and near-exact titles while
  # rejecting "The Island" vs "The Island of the Day Before" (0.33) and "Sapiens" vs
  # "Sapiens: A Brief History of Humankind" (0.17).
  @min_symmetry 0.6

  @doc """
  Best product path for `edition`, or `:no_match`.

  `listings` are `{product_path, title}` pairs as the shop lists them. `edition` needs
  `:title` and optionally `:author`.
  """
  @spec match_edition([{String.t(), String.t()}], map(), keyword()) ::
          {:ok, String.t(), float()} | :no_match
  def match_edition(listings, edition, opts \\ [])

  def match_edition([], _edition, _opts), do: :no_match

  def match_edition(listings, edition, opts) do
    floor = Keyword.get(opts, :floor, @floor)
    margin = Keyword.get(opts, :min_margin, @min_margin)

    signals = %{
      title: edition[:title] || edition["title"],
      author: edition[:author] || edition["author"]
    }

    # The product path stands in for the ISBN slot: CandidateScorer treats it as an
    # opaque identifier, so no adaptation is needed beyond naming.
    candidates = Enum.map(listings, fn {path, title} -> {path, %{title: title}} end)

    symmetry = Keyword.get(opts, :min_symmetry, @min_symmetry)

    case CandidateScorer.pick_best(candidates, signals, floor: floor) do
      {:ok, {score, path, meta}, runner_up} ->
        if clear_winner?(score, runner_up, margin) and
             symmetric_enough?(signals.title, meta[:title], symmetry) do
          {:ok, path, score}
        else
          Logger.debug(
            "StoreMatcher: #{inspect(signals.title)} matched #{path} at #{score} but the " <>
              "runner-up was too close to trust"
          )

          :no_match
        end

      # Below the floor: the best candidate is not plausibly the same book.
      {:floored, _best, _runner_up} ->
        :no_match

      :empty ->
        :no_match
    end
  end

  defp clear_winner?(_score, nil, _margin), do: true

  defp clear_winner?(score, {runner_score, _, _}, margin), do: score - runner_score >= margin

  # Jaccard, deliberately, not the overlap coefficient the scorer uses: overlap treats
  # a subset as a perfect match, which is exactly the case that must be rejected here.
  defp symmetric_enough?(ours, theirs, threshold)
       when is_binary(ours) and is_binary(theirs) do
    a = word_set(ours)
    b = word_set(theirs)
    union = MapSet.union(a, b)

    if MapSet.size(union) == 0 do
      false
    else
      MapSet.size(MapSet.intersection(a, b)) / MapSet.size(union) >= threshold
    end
  end

  defp symmetric_enough?(_ours, _theirs, _threshold), do: false

  defp word_set(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> MapSet.new()
  end
end
