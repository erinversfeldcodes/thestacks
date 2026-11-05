defmodule Stacks.Insights do
  @moduledoc """
      Personal inference & de-anonymisation education:
      computes, on the fly, what can be inferred about a user from their own
      shelf behaviour. Invariants (the point of the feature): STRICT own-only
      (every read hard-scoped to `user.id`); EPHEMERAL (nothing persisted —
      a stored inference would be a new special-category PII store needing its
      own erasure/export/consent); honestly labelled (facts as facts,
      inferences as guesses with their limits stated).
  """

  import Ecto.Query

  require Logger

  alias Core.Repo
  alias Stacks.Accounts.User
  alias Stacks.Books.Book
  alias Stacks.Scope
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

    # ⚠️ Scoped once at the context boundary rather than inside each helper: both
    # of these read row-level-secured tables, and a per-helper scope would open
    # and commit two transactions to answer one question about one user.
    {placements, history_times} =
      Scope.with_user(user_id, fn ->
        {active_placements(user_id), history_move_times(user_id)}
      end)

    # ⛔ DELIBERATELY OUTSIDE the scope above, and now answerable there.
    # `deanonymisation/2` asks how many OTHER users shelve the same rare books —
    # `bs.user_id <> subject` — which is the whole point of a uniqueness
    # fingerprint and cannot be answered from one user's rows. Scoped, the owner
    # policy admits only this user's rows and the `<>` then excludes them, so it
    # would return a confident ZERO and tell every reader they are maximally
    # identifiable.
    #
    # It goes through `op.count_others_sharing_all/3`, a SECURITY DEFINER
    # narrowed to this one question and returning one integer — the same
    # mechanism as the wishlist question and the transparency-page totals. That
    # function carries the argument guard, because a definer's arguments are its
    # whole attack surface.
    deanon = deanonymisation(user_id, placements)

    interest = interest_profile(placements)
    behaviour = behaviour(placements, history_times)

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

  # ⚖️ THE RAW COUNT SHIPS, and the alternative was weighed rather than skipped:
  # send `uniqueness` and the explanation text only, on the principle the public
  # aggregate page already follows — "counts are rounded to the nearest 10 to
  # prevent fingerprinting small user bases" (`docs/user-stories.md:282`).
  #
  # Withholding it buys nothing here, for three reasons that were measured
  # rather than assumed.
  #
  #   * The number identifies nobody on its own. Getting from
  #     `others_sharing_all: 1` to a person needs the size of the population
  #     and which reader it is, and this payload carries neither.
  #     `op.platform_row_counts()` publishes bookshelves, placements and active
  #     placements — no user count — so the platform does not supply the first
  #     of those anywhere else either.
  #   * `classify/1` preserves the only inference that matters anyway. It maps
  #     0 to "unique" and 1..5 to "rare", so the 0-versus-non-zero distinction
  #     — the whole of what a small population leaks — survives the bucket
  #     exactly. Sending the bucket alone removes no inference.
  #   * `explanation/2` interpolates the count into the prose, so redacting the
  #     field and keeping the sentence would be decoration, and dropping the
  #     sentence too would remove the surface's entire purpose.
  #
  # ⚠️ The rounding principle it was weighed against governs a PUBLIC aggregate
  # about other people. This number is about the subject's own exposure and is
  # shown only to the subject, and its smallness is precisely what the page
  # exists to teach. Rounding to the nearest 10 reports "no other reader" and
  # "four other readers" identically as zero, which misinforms in the direction
  # that matters.
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

  # ⚠️ The same confident-zero shape as `Books.community_read_count/1` had, one
  # module over, and it is kept here on purpose — with the difference stated.
  #
  # There, the caller is a book page rendering ONE number, so "I could not find
  # out" is a distinct and reportable answer. Here the map feeds a ranking over
  # many books, where an absent key already means "no count for this book" and
  # the aggregate degrades rather than lies: a book missing from the map simply
  # does not get a community-read contribution to its score.
  #
  # So an empty map is a legitimate degraded result, NOT a false zero — but the
  # FAILURE still has to be visible, which it was not. It emits the same
  # telemetry as its sibling, so one persistent cause shows up once rather than
  # as two unrelated silences.
  defp community_read_counts(book_ids) do
    sql =
      "SELECT book_id::text, read_count FROM marts.mart_community_read_count WHERE book_id = ANY($1::uuid[])"

    case Repo.query(sql, [book_ids]) do
      {:ok, %{rows: rows}} -> Map.new(rows, fn [id, count] -> {id, count} end)
      {:error, reason} -> read_counts_unavailable(reason)
    end
  rescue
    e -> read_counts_unavailable(e)
  end

  defp read_counts_unavailable(reason) do
    Logger.warning(
      "Insights.community_read_counts unavailable: #{inspect(reason)}. " <>
        "Rankings degrade without the community-read signal; a missing mart means the " <>
        "scheduled dbt refresh has not run."
    )

    :telemetry.execute([:stacks, :marts, :read_unavailable], %{count: 1}, %{
      mart: "mart_community_read_count"
    })

    %{}
  end

  # ⛔ THROUGH THE DEFINER, AND THE RESCUE IS GONE RATHER THAN KEPT AS A NET.
  #
  # The inline query asked `bs.user_id <> $2`, an aggregate over other readers'
  # rows, which no per-user scope can answer: scoped it returned a confident
  # ZERO and told every reader they were maximally identifiable; unscoped the
  # policy refused with 42501 and the rescue below reported "could not compute"
  # to every reader on every deployed stack since row-level security went on.
  #
  # ⚠️ The rescue is DELETED, not retained-and-proven-unreachable. Keeping it
  # would preserve this surface's whole failure character — that nobody becomes
  # suspicious. A refusal now propagates: `op.count_others_sharing_all/3`
  # raises `42501` on a NULL subject or a caller asking about somebody else,
  # and either is a defect in this module rather than a condition to paper
  # over. The remaining `log_and_nil/1` covers only a result shape Postgres
  # should never return, which is the one case where continuing is honest.
  defp count_others_sharing_all(user_id, book_ids, sample_size) do
    sql = "SELECT op.count_others_sharing_all($1::uuid, $2::uuid[], $3::integer)"

    case Repo.query(sql, [user_id, book_ids, sample_size]) do
      {:ok, %{rows: [[count]]}} -> count
      other -> log_and_nil(other)
    end
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
