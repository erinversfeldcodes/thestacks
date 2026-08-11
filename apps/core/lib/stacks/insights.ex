defmodule Stacks.Insights do
  @moduledoc """
  Personal inference & de-anonymisation education (Issue #242, ADR-019 §3a).

  Computes, **on the fly and strictly own-only**, a display payload teaching a
  signed-in user (a) what can be inferred about them from their own shelf
  behaviour and (b) how they could be de-anonymised even though the platform
  keeps no PII.

  ## Invariants (the point of the feature)

  - **Strict own-only.** Every read is hard-scoped to the given `user.id`.
    There is no parameter or code path that can select another user's data.
  - **Ephemeral — NEVER persisted.** Nothing here writes an inference, profile,
    or rarity row to `op.*` / `wh.*`. Persisting derived sensitive inferences
    would create a new special-category PII store needing its own
    erasure/export/consent — precisely what we must avoid. Compute and return.
  - **Honestly labelled.** Real facts (top subjects, counts) are shown as fact;
    `risk_inferences` are labelled illustrations of what a third party *could*
    infer, never asserted or stored, and are gated behind an explicit reveal.
  """

  import Ecto.Query

  require Logger

  alias Core.Repo
  alias Stacks.Accounts.User
  alias Stacks.Books.Book
  alias Stacks.Shelving.{Bookshelf, Placement, PlacementHistory}

  @fingerprint_size 5
  @top_subjects 8
  @top_bisac 8
  @risk_illustration_count 3

  @doc """
  Builds the personal-inference payload for `user`, own-only.

  Options:

    * `:reveal_risk` (boolean, default `false`) — when `true`, includes the
      `:risk_inferences` section (the consent-gated "what could be inferred"
      illustrations). When `false`, that key is omitted entirely.
  """
  @spec personal_inferences(User.t(), keyword()) :: map()
  def personal_inferences(%User{id: user_id}, opts \\ []) do
    reveal_risk? = Keyword.get(opts, :reveal_risk, false)

    placements = active_placements(user_id)
    history_times = history_move_times(user_id)

    interest = interest_profile(placements)
    behaviour = behaviour(placements, history_times)
    deanon = deanonymisation(user_id, placements)

    base = %{
      interest_profile: interest,
      behaviour: behaviour,
      deanonymisation: deanon,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    if reveal_risk? do
      Map.put(base, :risk_inferences, risk_inferences(interest))
    else
      base
    end
  end

  defp active_placements(user_id) do
    from(p in Placement,
      join: bs in Bookshelf,
      on: p.bookshelf_id == bs.id and bs.user_id == ^user_id,
      join: b in Book,
      on: b.id == p.book_id,
      where: is_nil(p.removed_at),
      select: %{
        book_id: p.book_id,
        subjects: b.subjects,
        bisac_codes: b.bisac_codes,
        reading_status: p.reading_status,
        started_at: p.started_at,
        finished_at: p.finished_at,
        placed_at: p.placed_at,
        bookshelf_name: bs.name
      }
    )
    |> Repo.all()
  end

  defp history_move_times(user_id) do
    bookshelf_ids =
      from(bs in Bookshelf, where: bs.user_id == ^user_id, select: bs.id) |> Repo.all()

    if bookshelf_ids == [] do
      []
    else
      from(h in PlacementHistory,
        where: h.from_bookshelf in ^bookshelf_ids or h.to_bookshelf in ^bookshelf_ids,
        select: h.moved_at
      )
      |> Repo.all()
    end
  end

  defp interest_profile(placements) do
    top_subjects =
      placements
      |> Enum.map(&(&1.subjects || []))
      |> top_counts(@top_subjects)
      |> Enum.map(fn {subject, count} -> %{subject: subject, count: count} end)

    top_bisac =
      placements
      |> Enum.map(&(&1.bisac_codes || []))
      |> top_counts(@top_bisac)
      |> Enum.map(fn {code, count} -> %{code: code, count: count} end)

    %{top_subjects: top_subjects, top_bisac: top_bisac}
  end

  defp top_counts(lists, n) do
    lists
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {value, count} -> {-count, value} end)
    |> Enum.take(n)
  end

  defp behaviour(placements, history_times) do
    total = length(placements)
    finished = Enum.count(placements, &(&1.reading_status == "completed"))
    abandoned = Enum.count(placements, &(&1.reading_status == "abandoned"))

    abandonment_rate =
      if total > 0, do: Float.round(abandoned / total, 3), else: 0.0

    %{
      books_shelved: total,
      books_finished: finished,
      books_abandoned: abandoned,
      abandonment_rate: abandonment_rate,
      median_days_to_finish: median_days_to_finish(placements),
      most_active_hour: most_active_hour(placements, history_times)
    }
  end

  defp median_days_to_finish(placements) do
    placements
    |> Enum.filter(&(&1.started_at && &1.finished_at))
    |> Enum.map(&DateTime.diff(&1.finished_at, &1.started_at, :day))
    |> Enum.reject(&(&1 < 0))
    |> median()
  end

  defp most_active_hour(placements, history_times) do
    hours =
      (Enum.map(placements, & &1.placed_at) ++ history_times)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.hour)

    case hours do
      [] ->
        nil

      _ ->
        hours
        |> Enum.frequencies()
        |> Enum.max_by(fn {hour, count} -> {count, -hour} end)
        |> elem(0)
    end
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(sorted, mid)
    else
      round((Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2)
    end
  end

  defp risk_inferences(%{top_subjects: top_subjects}) do
    top_subjects
    |> Enum.take(@risk_illustration_count)
    |> Enum.map(fn %{subject: subject} ->
      %{
        label: "Inferred topic interest",
        could_infer:
          "A data broker could infer an interest in #{subject} from your subject clusters.",
        basis: "subject cluster: #{subject}"
      }
    end)
  end

  defp deanonymisation(user_id, placements) do
    distinct_books = placements |> Enum.map(& &1.book_id) |> Enum.uniq()

    if length(distinct_books) < 2 do
      %{
        sample_size: length(distinct_books),
        others_sharing_all: nil,
        uniqueness: "insufficient_data",
        explanation:
          "Not enough shelf data yet to compute a fingerprint. Shelve a few books " <>
            "to see how identifiable your combination is."
      }
    else
      fingerprint = rarest_books(distinct_books)
      sample_size = length(fingerprint)
      others = count_others_sharing_all(user_id, fingerprint, sample_size)

      %{
        sample_size: sample_size,
        others_sharing_all: others,
        uniqueness: classify(others),
        explanation: explanation(others, sample_size)
      }
    end
  end

  defp rarest_books(distinct_books) do
    counts = community_read_counts(distinct_books)

    distinct_books
    |> Enum.sort_by(fn id -> {Map.get(counts, id, 0), id} end)
    |> Enum.take(@fingerprint_size)
  end

  defp community_read_counts([]), do: %{}

  defp community_read_counts(book_ids) do
    sql =
      "SELECT book_id::text, read_count FROM wh.mart_community_read_count WHERE book_id = ANY($1::uuid[])"

    case Repo.query(sql, [book_ids]) do
      {:ok, %{rows: rows}} -> Map.new(rows, fn [id, count] -> {id, count} end)
      _ -> %{}
    end
  rescue
    e ->
      Logger.warning("Insights.community_read_counts failed: #{inspect(e)}")
      %{}
  end

  defp count_others_sharing_all(user_id, book_ids, sample_size) do
    sql = """
    SELECT count(*) FROM (
      SELECT bs.user_id
      FROM op.bookshelf_placements p
      JOIN op.bookshelves bs ON bs.id = p.bookshelf_id
      WHERE p.book_id = ANY($1::uuid[]) AND p.removed_at IS NULL AND bs.user_id <> $2::uuid
      GROUP BY bs.user_id
      HAVING count(DISTINCT p.book_id) = $3
    ) t
    """

    case Repo.query(sql, [book_ids, user_id, sample_size]) do
      {:ok, %{rows: [[count]]}} -> count
      other -> log_and_nil(other)
    end
  rescue
    e ->
      Logger.warning("Insights.count_others_sharing_all failed: #{inspect(e)}")
      nil
  end

  defp log_and_nil(other) do
    Logger.warning("Insights.count_others_sharing_all unexpected result: #{inspect(other)}")
    nil
  end

  defp classify(nil), do: "unknown"
  defp classify(0), do: "unique"
  defp classify(k) when k <= 5, do: "rare"
  defp classify(_), do: "common"

  defp explanation(nil, sample_size) do
    "Could not compute how many others share your #{sample_size} rarest books right now."
  end

  defp explanation(0, sample_size) do
    "No other reader here shares all #{sample_size} of your rarest books. That combination " <>
      "is a fingerprint: it could be cross-referenced with public data (a Goodreads profile, " <>
      "a tweet about a niche book) to re-identify you — no name or email required."
  end

  defp explanation(k, sample_size) do
    "#{k} other reader(s) here share all #{sample_size} of your rarest books. The smaller " <>
      "that number, the more your shelf acts as a fingerprint that could be cross-referenced " <>
      "with public data to re-identify you — no name or email required."
  end
end
