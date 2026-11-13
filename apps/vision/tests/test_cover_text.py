"""The CPU cover-text pass, and the places its heuristics are wrong.

⛔ THIS TIER RETURNS A CLAIM, NOT AN IDENTIFICATION. Most of what is asserted
here is about restraint: that it declines rather than guesses, that it never
fabricates an ISBN, and that a failure inside it falls through to the VLM
instead of taking the request down. A tier that answers confidently and wrongly
is worse than one that answers less often.
"""

from __future__ import annotations

from typing import Any
from unittest.mock import patch

from app.services.cover_text import ENGINE, read_cover_text


def _word(text: str, conf: float, height: float) -> dict[str, Any]:
    return {"text": text, "conf": conf, "height": height}


def _tesseract_returning(words: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "text": [w["text"] for w in words],
        "conf": [w["conf"] for w in words],
        "height": [w["height"] for w in words],
    }


def _read_with(words: list[dict[str, Any]]) -> Any:
    """Drive the real function with a stubbed engine response.

    ⚠️ Only `image_to_data` is stubbed. The word filtering, the title
    heuristic and the author rule are all the real code — stubbing those
    would leave the tests agreeing with a reimplementation of the rule
    rather than with the rule.
    """
    with (
        patch("pytesseract.image_to_data", return_value=_tesseract_returning(words)),
        patch("PIL.Image.open"),
    ):
        return read_cover_text(b"not-a-real-image")


class TestTitleHeuristic:
    def test_the_largest_set_words_become_the_title(self) -> None:
        got = _read_with(
            [
                _word("THE", 92, 80),
                _word("ALCHEMIST", 94, 82),
                _word("a", 70, 20),
                _word("novel", 71, 22),
                _word("Paulo", 88, 30),
                _word("Coelho", 89, 30),
            ]
        )
        assert got.title == "THE ALCHEMIST", (
            "the title block is the largest type on the cover; the blurb and "
            f"byline are set smaller and must not join it — got {got.title!r}"
        )

    def test_publisher_furniture_is_dropped_even_at_title_size(self) -> None:
        got = _read_with(
            [
                _word("BELOVED", 95, 82),
                _word("A", 90, 80),
                _word("NOVEL", 91, 80),
            ]
        )
        assert got.title == "BELOVED", (
            "'A NOVEL' is set in title-sized type on a great many covers and "
            f"is never part of the title — got {got.title!r}"
        )

    # ⛔ THE REGRESSION THIS RULE WAS REWRITTEN FOR. An earlier version stripped
    # "the", "a" and "of" as individual words anywhere in the title, which
    # turned this into "Lord Rings". Articles and prepositions ARE part of
    # titles; only the publisher's own furniture phrases are not.
    def test_articles_and_prepositions_survive_inside_a_title(self) -> None:
        got = _read_with(
            [
                _word("THE", 94, 80),
                _word("LORD", 95, 80),
                _word("OF", 93, 80),
                _word("THE", 94, 80),
                _word("RINGS", 95, 80),
            ]
        )
        assert got.title == "THE LORD OF THE RINGS", (
            f"stripping common words anywhere mangles real titles — got {got.title!r}"
        )

    # ⛔ THE PHRASE RULE'S OWN TEST. Every other furniture case here is
    # actually settled by the trailing-word rule, because `_MIN_WORD_CHARS`
    # eats the article in "A NOVEL" before a phrase can match — so without a
    # multi-word phrase whose every word is two characters or more, the phrase
    # list is dead code that no test touches. A probe disabling it passed 15
    # tests before this one existed.
    def test_a_multi_word_furniture_phrase_is_stripped(self) -> None:
        got = _read_with(
            [
                _word("EMMA", 95, 80),
                _word("PENGUIN", 90, 78),
                _word("CLASSICS", 90, 78),
            ]
        )
        assert got.title == "EMMA", (
            "'PENGUIN CLASSICS' is a publisher imprint set in title-sized "
            f"type, not part of the title — got {got.title!r}"
        )

    def test_a_cover_whose_largest_type_is_only_furniture_has_no_title(self) -> None:
        got = _read_with([_word("A", 90, 80), _word("NOVEL", 91, 80)])
        assert got.title is None, (
            "removing a furniture phrase can empty the title, and an empty "
            f"result is a miss rather than the empty string — got {got.title!r}"
        )

    # ⛔ THE HEURISTIC'S KNOWN FAILURE, ASSERTED SO IT CANNOT CHANGE IN SILENCE.
    # On a famous author's book the NAME is often set larger than the title.
    # "largest type is the title" then returns the author. This is why the eval
    # corpus has a hostile-typography stratum and why this test documents the
    # wrong answer rather than hiding it.
    def test_an_author_set_larger_than_the_title_is_returned_as_the_title(self) -> None:
        got = _read_with(
            [
                _word("STEPHEN", 96, 90),
                _word("KING", 96, 90),
                _word("Misery", 93, 40),
            ]
        )
        assert got.title == "STEPHEN KING", (
            "documented failure: when the author outsizes the title this "
            "heuristic returns the author. Measured on the corpus, not fixed "
            f"by guessing — got {got.title!r}"
        )

    def test_low_confidence_words_are_dropped(self) -> None:
        got = _read_with(
            [
                _word("DUNE", 95, 80),
                _word("XXVII", 12, 80),
            ]
        )
        assert got.title == "DUNE", (
            "a word the engine barely recognised corrupts a title more than "
            f"dropping it loses — got {got.title!r}"
        )

    def test_single_characters_are_dropped(self) -> None:
        got = _read_with([_word("I", 90, 80), _word("ROBOT", 94, 80)])
        assert got.title == "ROBOT", (
            "stray marks read as single letters are the most common cover "
            f"artefact — got {got.title!r}"
        )


class TestAuthor:
    def test_an_explicit_by_marker_yields_the_author(self) -> None:
        got = _read_with(
            [
                _word("EMMA", 95, 80),
                _word("by", 80, 30),
                _word("Jane", 88, 30),
                _word("Austen", 89, 30),
            ]
        )
        assert got.author == "Jane Austen"

    # ⬛ ANTI-VACUITY for the test above: without this, an author hardcoded to
    # a constant would pass it.
    def test_no_by_marker_yields_no_author(self) -> None:
        got = _read_with([_word("EMMA", 95, 80), _word("Austen", 88, 30)])
        assert got.author is None, (
            "inferring an author from position is wrong often enough on real "
            "covers that a confident wrong author is worse than none; the "
            f"platform's title search accepts a nil author — got {got.author!r}"
        )


class TestRestraint:
    def test_nothing_readable_yields_no_title_and_no_text(self) -> None:
        got = _read_with([])
        assert got.title is None
        assert got.raw_text == ""
        assert got.confidence == 0.0

    # ⚠️ The two misses are DIFFERENT FACTS and the measurement depends on
    # telling them apart: "read text but found no title" is a heuristic
    # failure, "read nothing" is an engine or image failure.
    def test_text_read_but_no_title_keeps_the_raw_text(self) -> None:
        got = _read_with([_word("A", 90, 40), _word("NOVEL", 90, 40)])
        assert got.title is None, "all furniture, so no title survives"
        assert got.raw_text, (
            "raw text must survive a title miss, or a hard cover is "
            "indistinguishable from a broken engine"
        )

    # ⛔ THE SAFETY CONTRACT. This sits in front of the VLM on the live path,
    # so an exception here must degrade to "the VLM answers", never to a 500.
    def test_an_engine_failure_falls_through_instead_of_raising(self) -> None:
        with (
            patch("pytesseract.image_to_data", side_effect=RuntimeError("boom")),
            patch("PIL.Image.open"),
        ):
            got = read_cover_text(b"anything")
        assert got.title is None
        assert got.confidence == 0.0

    def test_a_corrupt_image_falls_through_instead_of_raising(self) -> None:
        got = read_cover_text(b"\x00\x01not-an-image")
        assert got.title is None, "a decode failure is a fall-through, not a crash"

    def test_the_engine_names_itself(self) -> None:
        got = _read_with([_word("DUNE", 95, 80)])
        assert got.engine == ENGINE, (
            "a measurement that cannot say which engine produced it cannot be "
            "attributed to a version"
        )

    def test_confidence_is_the_mean_over_kept_words_normalised(self) -> None:
        got = _read_with([_word("DUNE", 90, 80), _word("MESSIAH", 70, 80)])
        assert got.confidence == 0.8, (
            "the short-circuit gate reads this number, so its scale is "
            f"load-bearing: 0..1, not 0..100 — got {got.confidence}"
        )
