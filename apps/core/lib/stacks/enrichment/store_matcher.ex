defmodule Stacks.Enrichment.StoreMatcher do
  @moduledoc """
  Matches a bookshop's product titles to our editions, for shops with no
  ISBN on any product (Ike's Books, Love Books — title matching is the
  only path, and it lives here because only core knows the catalogue).
  Reuses `CandidateScorer` — the same weighted overlap, plausibility
  floor and derivative penalty the ISBN resolver uses, already tuned and
  eval-harnessed — rather than a second matcher with a second set of
  weights to drift. Matches record provenance (`title_match` + score) so
  a fuzzy match is never mistaken for an ISBN-verified one.
  """

  require Logger

  alias Stacks.Books.CandidateScorer

  @floor 3.0

  @min_margin 1.0

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

      {:floored, _best, _runner_up} ->
        :no_match

      :empty ->
        :no_match
    end
  end

  defp clear_winner?(_score, nil, _margin), do: true

  defp clear_winner?(score, {runner_score, _, _}, margin), do: score - runner_score >= margin

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
