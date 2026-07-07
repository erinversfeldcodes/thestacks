defmodule Stacks.Books.CandidateScorerTest do
  use ExUnit.Case, async: true

  alias Stacks.Books.CandidateScorer

  # The production failure this scorer exists to fix: fixture
  # `screenshot_image_reversed_and_cut_off.jpg` ("Train to Crystal
  # City" E2E test). The VLM enriches the title with subtitle keywords
  # and invents the author; OL ranks Orson Scott Card's fantasy novel
  # first on exact-prefix match, but Jan Jarboe Russell's book (doc #3
  # in the same response) is the correct one.
  #
  # Fixtures below mirror the REAL Open Library response (verified
  # against the live API 2026-06-10): OL returns `subtitle: nil` for
  # every doc, so disambiguation has to come from the `subjects` lists.
  # Subjects are the first 5 entries, matching the resolver's
  # `Enum.take(5)`.
  @crystal_city_signals %{
    title: "The Crystal City: The Tragedy of America's First Internment Camp",
    author: "Doris Akers",
    raw_text: "THE CRYSTAL CI IT IS ABOUT F DRS"
  }

  @card_candidate %{
    title: "The Crystal City",
    subtitle: nil,
    author: "Orson Scott Card",
    subjects: [
      "Alvin Maker (Fictitious character)",
      "Fiction",
      "Magic",
      "Frontier and pioneer life",
      "Fiction, fantasy, general"
    ]
  }

  @tarantino_candidate %{
    title: "The Crystal City",
    subtitle: nil,
    author: "Janice Tarantino",
    subjects: []
  }

  @russell_candidate %{
    title: "The train to Crystal City",
    subtitle: nil,
    author: "Jan Jarboe Russell",
    subjects: [
      "Concentration camps",
      "German Americans",
      "World War, 1939-1945",
      "Crystal City Internment Camp (Crystal City, Tex.)",
      "Evacuation of civilians"
    ]
  }

  @etchemendy_candidate %{
    title: "The crystal city",
    subtitle: nil,
    author: "Nancy Etchemendy",
    subjects: ["Science fiction", "Children's fiction"]
  }

  describe "score/2 — Crystal City disambiguation (real OL data)" do
    test "Russell's book outscores Card's by a comfortable margin despite Card's exact-prefix title" do
      card_score = CandidateScorer.score(@card_candidate, @crystal_city_signals)
      russell_score = CandidateScorer.score(@russell_candidate, @crystal_city_signals)

      assert russell_score >= card_score + 0.5

      # Pin the component arithmetic documented in the moduledoc:
      # Card    = overlap 3.0 * 2/2 + subjects 0 + raw_text 1.5 * 1/3 = 3.5
      # Russell = overlap 3.0 * 2/3
      #         + subjects 1.0 * min(4, 3)   ({crystal city internment camp})
      #         + raw_text 1.5 * 1/3                                  = 5.5
      assert_in_delta card_score, 3.5, 0.001
      assert_in_delta russell_score, 5.5, 0.001
    end

    test "neither Tarantino nor Etchemendy beats Russell" do
      russell_score = CandidateScorer.score(@russell_candidate, @crystal_city_signals)
      tarantino_score = CandidateScorer.score(@tarantino_candidate, @crystal_city_signals)
      etchemendy_score = CandidateScorer.score(@etchemendy_candidate, @crystal_city_signals)

      assert russell_score > tarantino_score
      assert russell_score > etchemendy_score

      # Both collapse to the same exact-prefix shape as Card: no
      # subject hits, only the "crystal" raw_text hit.
      assert_in_delta tarantino_score, 3.5, 0.001
      assert_in_delta etchemendy_score, 3.5, 0.001
    end

    test "subject evidence is the disambiguator: Russell without subjects loses it all" do
      stripped = %{@russell_candidate | subjects: []}

      full_score = CandidateScorer.score(@russell_candidate, @crystal_city_signals)
      stripped_score = CandidateScorer.score(stripped, @crystal_city_signals)

      assert full_score > stripped_score
      # overlap 2.0 + raw_text 0.5 — without subjects Russell would
      # lose to Card's exact-prefix 3.5.
      assert_in_delta stripped_score, 2.5, 0.001
    end
  end

  describe "score/2 — subject evidence" do
    test "subject hits are capped at 3 (no subject-spam inflation)" do
      signals = %{
        title: "The Crystal City: The Tragedy of America's First Internment Camp",
        author: nil,
        raw_text: nil
      }

      # All 7 signal tokens appear across the subjects — only 3 count.
      spammy = %{
        title: "Unrelated",
        subtitle: nil,
        author: nil,
        subjects: [
          "Crystal City",
          "Internment camps",
          "Tragedy",
          "America's first camps",
          "First-hand accounts"
        ]
      }

      # No title overlap ("unrelated" shares nothing), no raw_text:
      # the score is purely the capped subject component.
      assert_in_delta CandidateScorer.score(spammy, signals), 3.0, 0.001
    end

    test "missing or empty subjects contribute nothing" do
      signals = %{title: "Internment Camp", author: nil, raw_text: nil}
      base = %{title: "Gatsby", subtitle: nil, author: nil}

      assert CandidateScorer.score(Map.put(base, :subjects, []), signals) ==
               CandidateScorer.score(base, signals)
    end

    test "raw_text tokens also hit subjects, not just title+subtitle" do
      # "Internment camps" shares no token with the signal TITLE, so
      # subject evidence stays 0 — the score difference is purely the
      # raw_text component matching against the subjects text.
      signals = %{title: "Crystal City", author: nil, raw_text: "internment"}

      with_subject = %{
        title: "The train to Crystal City",
        subtitle: nil,
        author: nil,
        subjects: ["Internment camps"]
      }

      without_subject = %{with_subject | subjects: []}

      assert CandidateScorer.score(with_subject, signals) -
               CandidateScorer.score(without_subject, signals) > 1.0
    end
  end

  describe "score/2 — subtitle evidence (Google Books supplies subtitles)" do
    test "subtitle evidence still fires when a subtitle IS present" do
      # GB returns real subtitles even though OL search docs don't —
      # this is the GB-shaped Russell candidate.
      gb_russell = %{
        title: "The Train to Crystal City",
        subtitle:
          "FDR's Secret Internment Camp and America's Only Family " <>
            "Internment Camp During World War II",
        author: "Jan Jarboe Russell",
        subjects: []
      }

      stripped = %{gb_russell | subtitle: nil}

      full_score = CandidateScorer.score(gb_russell, @crystal_city_signals)
      stripped_score = CandidateScorer.score(stripped, @crystal_city_signals)

      # Subtitle adds token overlap ({internment camp americas first}),
      # subtitle evidence, and the "fdrs" raw_text hit.
      assert full_score > stripped_score

      gb_card = Map.put(@card_candidate, :subjects, [])
      assert full_score > CandidateScorer.score(gb_card, @crystal_city_signals)
    end
  end

  describe "score/2 — exact title match" do
    test "exact title match beats partial overlap (easy-case protection)" do
      signals = %{title: "The Great Gatsby", author: nil, raw_text: nil}

      exact = %{title: "The Great Gatsby", subtitle: nil, author: nil}
      partial = %{title: "The Great Gatsby Murder Mysteries", subtitle: nil, author: nil}

      assert CandidateScorer.score(exact, signals) >
               CandidateScorer.score(partial, signals)
    end
  end

  describe "score/2 — author signal" do
    test "shared surname adds a bonus" do
      signals = %{title: "The Train to Crystal City", author: "Jan Jarboe Russell", raw_text: nil}

      with_author = %{
        title: "The Train to Crystal City",
        subtitle: nil,
        author: "Jan Jarboe Russell"
      }

      without_author = %{title: "The Train to Crystal City", subtitle: nil, author: nil}

      assert CandidateScorer.score(with_author, signals) >
               CandidateScorer.score(without_author, signals)
    end

    test "absence of an author match does not penalise (positive-evidence-only)" do
      base_signals = %{title: "The Train to Crystal City", author: nil, raw_text: nil}
      invented_signals = %{base_signals | author: "Doris Akers"}

      candidate = %{
        title: "The Train to Crystal City",
        subtitle: nil,
        author: "Jan Jarboe Russell"
      }

      # An invented (mismatching) VLM author must score the same as no
      # author at all — never lower.
      assert CandidateScorer.score(candidate, invented_signals) ==
               CandidateScorer.score(candidate, base_signals)
    end

    test "nil signal author is safe" do
      signals = %{title: "Gatsby", author: nil, raw_text: nil}
      candidate = %{title: "Gatsby", subtitle: nil, author: "F. Scott Fitzgerald"}

      assert is_float(CandidateScorer.score(candidate, signals))
    end

    test "the literal string \"null\" as signal author yields no author evidence" do
      # Moderation normalises null-ish authors to nil before the scorer
      # ever sees them, but defence-in-depth: even if "null" leaks
      # through, it must score identically to no author at all.
      candidate = %{title: "Gatsby", subtitle: nil, author: "F. Scott Fitzgerald"}

      null_signals = %{title: "Gatsby", author: "null", raw_text: nil}
      nil_signals = %{title: "Gatsby", author: nil, raw_text: nil}

      assert CandidateScorer.score(candidate, null_signals) ==
               CandidateScorer.score(candidate, nil_signals)

      refute CandidateScorer.author_match?(candidate, null_signals)
    end
  end

  describe "author_match?/2" do
    test "true when the signal author's surname appears in the candidate author" do
      candidate = %{title: "X", subtitle: nil, author: "Jan Jarboe Russell"}
      signals = %{title: "Y", author: "J. Russell", raw_text: nil}

      assert CandidateScorer.author_match?(candidate, signals)
    end

    test "false for nil or mismatching signal author" do
      candidate = %{title: "X", subtitle: nil, author: "Jan Jarboe Russell"}

      refute CandidateScorer.author_match?(candidate, %{title: "Y", author: nil, raw_text: nil})

      refute CandidateScorer.author_match?(candidate, %{
               title: "Y",
               author: "Doris Akers",
               raw_text: nil
             })
    end

    test "false when the candidate has no author" do
      candidate = %{title: "X", subtitle: nil, author: nil}
      signals = %{title: "Y", author: "Jan Jarboe Russell", raw_text: nil}

      refute CandidateScorer.author_match?(candidate, signals)
    end
  end

  describe "score/2 — raw_text fragments" do
    test "OCR fragment 'F DRS' matches a candidate whose subtitle contains FDR's" do
      signals = %{title: "Crystal City", author: nil, raw_text: "F DRS"}

      with_fdr = %{
        title: "The train to Crystal City",
        subtitle: "FDR's Secret Internment Camp",
        author: nil
      }

      without_fdr = %{title: "The train to Crystal City", subtitle: nil, author: nil}

      assert CandidateScorer.score(with_fdr, signals) >
               CandidateScorer.score(without_fdr, signals)
    end

    test "'F DRS' collapses to the single token fdrs (pinned component arithmetic)" do
      # Isolate the raw_text component: nil title/author means the only
      # possible contribution is raw_text 1.5 * 1/1 — which requires
      # "f drs" to have collapsed into exactly one token, "fdrs".
      signals = %{title: nil, author: nil, raw_text: "F DRS"}

      candidate = %{
        title: nil,
        subtitle: "FDR's Secret Internment Camp",
        author: nil
      }

      assert_in_delta CandidateScorer.score(candidate, signals), 1.5, 0.001
    end

    test "possessive apostrophes yield one token — 'TRAMP'S' never becomes an orphan s (scrystal bug)" do
      # All three raw_text tokens ({tramps, crystal, city}) must be
      # found in the identically-titled candidate: raw_text 1.5 * 3/3.
      # If the apostrophe produced an orphan "s" glued onto the next
      # word ("scrystal"), that token would miss and the score would
      # drop below 1.5.
      signals = %{title: nil, author: nil, raw_text: "THE TRAMP'S CRYSTAL CITY"}

      candidate = %{title: "The Tramp's Crystal City", subtitle: nil, author: nil}

      assert_in_delta CandidateScorer.score(candidate, signals), 1.5, 0.001
    end
  end

  describe "score/2 — stopwords" do
    test "stopwords don't inflate scores" do
      signals = %{title: "The City of the Sun", author: nil, raw_text: nil}

      real_match = %{title: "The City of the Sun", subtitle: nil, author: nil}
      unrelated = %{title: "The City", subtitle: nil, author: nil}

      assert CandidateScorer.score(real_match, signals) >
               CandidateScorer.score(unrelated, signals)
    end
  end

  describe "score/2 — degenerate inputs" do
    test "all-nil signals and sparse candidate return 0.0" do
      assert CandidateScorer.score(
               %{title: nil, subtitle: nil, author: nil},
               %{title: nil, author: nil, raw_text: nil}
             ) == 0.0
    end
  end

  # The production failure the penalty exists to fix (Klara and the
  # Sun, chore/enable-pipelines): a GB "Study Guide: ..." derivative
  # whose title absorbs the author tokens (raw_text 4/4 vs the real
  # work's 2/4) and whose author GB mislabels as Ishiguro himself, so
  # it collects the author bonus AND the floor waiver. Pinned in the
  # eval corpus as `klara_study_guide` (`mix eval.resolver`).
  @klara_signals %{
    title: "Klara and the Sun",
    author: "Kazuo Ishiguro",
    raw_text: "KLARA AND THE SUN KAZUO ISHIGURO"
  }

  @klara_real %{
    title: "Klara and the Sun",
    subtitle: nil,
    author: "Kazuo Ishiguro",
    subjects: ["Fiction", "Science fiction"]
  }

  @klara_derivative %{
    title: "Study Guide: Klara and the Sun by Kazuo Ishiguro",
    subtitle: nil,
    author: "Kazuo Ishiguro",
    subjects: ["Study Aids"]
  }

  describe "score/3 — derivative-title penalty" do
    test "with the penalty disabled the derivative outscores the real work (the bug)" do
      off = [weights: [derivative_penalty: 0.0]]

      real = CandidateScorer.score(@klara_real, @klara_signals, off)
      derivative = CandidateScorer.score(@klara_derivative, @klara_signals, off)

      # Pin the inversion: derivative 5.5 (overlap 3.0 + raw 4/4 = 1.5
      # + author 1.0) vs real 5.25 (overlap 3.0 + raw 2/4 = 0.75 +
      # author 1.0 + exact 0.5).
      assert_in_delta derivative, 5.5, 0.001
      assert_in_delta real, 5.25, 0.001
    end

    test "the default penalty flips the pick to the real work" do
      real = CandidateScorer.score(@klara_real, @klara_signals)
      derivative = CandidateScorer.score(@klara_derivative, @klara_signals)

      assert real > derivative
      # 5.5 - 2.0 default penalty
      assert_in_delta derivative, 3.5, 0.001
    end

    test "no penalty when the SIGNAL title also carries the marker (user photographed an actual study guide)" do
      signals = %{
        title: "Study Guide: Klara and the Sun by Kazuo Ishiguro",
        author: nil,
        raw_text: nil
      }

      # Exact-title match on the derivative itself — the penalty must
      # not fire, so the score includes the full overlap + exact bonus.
      assert CandidateScorer.score(@klara_derivative, signals) >=
               CandidateScorer.score(@klara_real, signals)
    end

    test "penalty matches title tokens only — a marker in the subjects does not penalise" do
      signals = %{title: "Klara and the Sun", author: nil, raw_text: nil}

      with_marker_subject = %{
        title: "Klara and the Sun",
        subtitle: nil,
        author: nil,
        subjects: ["Study Aids"]
      }

      without = %{with_marker_subject | subjects: []}

      assert CandidateScorer.score(with_marker_subject, signals) >=
               CandidateScorer.score(without, signals)
    end

    test "weights are overridable per call" do
      derivative = CandidateScorer.score(@klara_derivative, @klara_signals)

      heavier =
        CandidateScorer.score(@klara_derivative, @klara_signals,
          weights: [derivative_penalty: 4.0]
        )

      assert_in_delta derivative - heavier, 2.0, 0.001
    end
  end

  # `pick_best/3` is the seam shared by `ISBNResolver.pick_best_candidate/3`
  # and `mix eval.resolver` — pick + plausibility floor + author waiver.
  describe "pick_best/3" do
    test "empty candidate list is :empty" do
      assert CandidateScorer.pick_best([], @crystal_city_signals) == :empty
    end

    test "picks the max-scoring candidate and returns the runner-up" do
      candidates = [
        {"9781429964500", @card_candidate},
        {"9781451693669", @russell_candidate}
      ]

      assert {:ok, {best_score, "9781451693669", _meta}, {runner_score, "9781429964500", _}} =
               CandidateScorer.pick_best(candidates, @crystal_city_signals)

      assert_in_delta best_score, 5.5, 0.001
      assert_in_delta runner_score, 3.5, 0.001
    end

    test "a lone below-floor candidate without author corroboration is floored" do
      garbage = %{
        title: "The Crystal Ball a Mystery Story for Girls",
        subtitle: nil,
        author: "Roy J. Snell",
        subjects: ["Fiction"]
      }

      signals = %{
        title: "The Tramp's Crystal City",
        author: nil,
        raw_text: "THE TRAMP'S CRYSTAL CITY"
      }

      assert {:floored, {score, "9781532774393", _meta}, nil} =
               CandidateScorer.pick_best([{"9781532774393", garbage}], signals)

      assert score < CandidateScorer.default_floor()
    end

    test "author corroboration waives the floor" do
      candidate = %{
        title: "Completely Different Title",
        subtitle: nil,
        author: "Jan Jarboe Russell",
        subjects: []
      }

      signals = %{title: "Zork", author: "Jan Jarboe Russell", raw_text: nil}

      assert {:ok, {_score, "9781451693669", _meta}, nil} =
               CandidateScorer.pick_best([{"9781451693669", candidate}], signals)
    end

    test "the floor is overridable per call (tuning experiments)" do
      # The junk record from the July production sessions: subset title
      # overlap + raw_text = exactly 3.0, nothing else. Above the 2.5
      # default floor, below an experimental 3.25 one.
      junk = %{title: "Crystal City-CC", subtitle: nil, author: nil, subjects: []}

      signals = %{
        title: "The Tramp's Crystal City",
        author: nil,
        raw_text: "THE TRAMP'S CRYSTAL CITY"
      }

      assert {:ok, {score, "0812444647", _}, nil} =
               CandidateScorer.pick_best([{"0812444647", junk}], signals)

      assert_in_delta score, 3.0, 0.001

      assert {:floored, {_score, "0812444647", _}, nil} =
               CandidateScorer.pick_best([{"0812444647", junk}], signals, floor: 3.25)
    end
  end
end
