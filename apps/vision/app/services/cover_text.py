"""Reading a cover's text on CPU, in the container that is already warm.

⛔ WHAT THIS TIER IS NOT. The barcode pass returns an **identification**: an
ISBN carries its own checksum, so a decode is self-verifying and false
positives are near zero. This pass returns a **claim** — a title, maybe an
author — which the platform must still resolve against Open Library or Google
Books before anything enters the catalogue. The ISBN hard gate is satisfied by
that resolution, never by this function. Treating the two tiers as equivalent
would let a misread title become a verified edition.

⚖️ WHY CPU IS THE POINT, AND WHY IT IS NEARLY FREE HERE. The sidecar runs two
Modal functions: the A10G model class, and this FastAPI front door on CPU with
a 1200s scaledown. Every request passes through the front door to reach the GPU
at all, so this container is warm by construction. Text read here therefore
adds no cold start and opens no new billable container lifetime — unlike the
GPU, where a single identification after a quiet period pays a 300s idle tail
that measurement put at ~9.8c against 0.18c of actual compute.

⚠️ SHADOW BY DEFAULT. `VISION_OCR_SHORT_CIRCUIT` is off, so this runs and is
recorded while the VLM still answers. That is deliberate: it measures what the
tier WOULD have answered against what the VLM DID answer, on the same image, in
one run — which is the only way to get a hit rate without first trusting the
thing being measured.
"""

from __future__ import annotations

import io
import logging
import re
from dataclasses import dataclass
from typing import Any, TypedDict

logger = logging.getLogger(__name__)


class _Word(TypedDict):
    """One word the engine kept, with the two facts the heuristics read."""

    text: str
    conf: float
    height: float


ENGINE = "tesseract"

# Punctuation stripped from the edges of a read title. The en and em dashes are
# written as escapes because they are deliberate — display type sets them as
# separators, and a title that genuinely ends in one is rare enough that
# trimming is the right default.
_EDGE_PUNCT = " -\u2013\u2014:,."

# Words shorter than this are dropped before a title is assembled. Cover
# clutter ("a", "of", stray marks read as letters) is mostly 1-2 characters,
# while almost no real title word is.
_MIN_WORD_CHARS = 2

# Tesseract reports per-word confidence 0..100, and -1 for a box it kept but
# could not score. Below this, a word is noise often enough that including it
# corrupts the title more than dropping it loses.
_MIN_WORD_CONF = 55.0

# A cover's title is set larger than its blurb. Keeping only words whose box
# height is within this fraction of the tallest word is a crude but effective
# proxy for "part of the title block" — it survives rotation and is far cheaper
# than layout analysis.
_TITLE_HEIGHT_RATIO = 0.62

# Publisher furniture that sits in title-sized type on many covers and is never
# part of a title.
#
# ⛔ PHRASES, NOT COMMON WORDS. An earlier version listed "the", "a", "of" and
# "new" individually and stripped them anywhere in the title — which turned
# "The Lord of the Rings" into "Lord Rings" and "The Road" into "Road". Articles
# and prepositions ARE part of titles; only the publisher's own furniture is
# not. Matched as whole phrases against the assembled title, case-folded.
_FURNITURE_PHRASES = (
    "a novel",
    "the novel",
    "new york times bestseller",
    "new york times bestselling author",
    "international bestseller",
    "sunday times bestseller",
    "bestselling author",
    "penguin classics",
    "with a new introduction",
    "deluxe edition",
    "anniversary edition",
)

# Furniture that survives phrase matching because an earlier filter ate its
# article: "A NOVEL" loses the "A" to `_MIN_WORD_CHARS` before the phrase can
# match, leaving a bare "NOVEL" glued to the title.
#
# ⚖️ Stripped ONLY at the end of a title. These are tag words a publisher
# appends; the same word leading a title ("Novel Ideas") is the title's own.
# Applying them anywhere would repeat the mistake the phrase rule was written
# to fix.
_TRAILING_FURNITURE = ("novel", "bestseller", "edition", "classics")


@dataclass(frozen=True)
class CoverText:
    """What the pass read. Every field is reported, including on a miss.

    ⚠️ `title is None` and `raw_text == ""` are different facts: the first says
    nothing title-shaped was found in text that WAS read, the second says
    nothing was read at all. A measurement that collapses them cannot tell a
    hard cover from a broken engine.
    """

    title: str | None
    author: str | None
    raw_text: str
    confidence: float
    engine: str = ENGINE


_EMPTY = CoverText(title=None, author=None, raw_text="", confidence=0.0)

# ⛔ A MISSING ENGINE MUST NOT READ AS "FOUND NOTHING". The catch-all below
# exists so this tier can never take a request down, and it will happily
# swallow an ImportError from a container where tesseract did not install —
# producing a run of empty reads that looks exactly like "OCR is useless on
# these covers". That is the silent zero this project keeps relearning: before
# believing a zero, make a non-zero distinguishable from a broken pipe.
_UNAVAILABLE = CoverText(title=None, author=None, raw_text="", confidence=0.0, engine="unavailable")


def read_cover_text(image_bytes: bytes) -> CoverText:
    """Read a cover's text. NEVER raises — a failure returns an empty read.

    The safety contract matches `local_isbn_scan`: this sits in front of the
    VLM on the live path, so any exception here must degrade to "the VLM
    answers", never to a 500. A tier that can take the request down is worse
    than no tier.
    """
    try:
        return _read(image_bytes)
    except ImportError:
        # Reported as its own engine value so an artefact set can be told
        # apart from one where the engine ran and found nothing.
        logger.error("cover text engine is not installed in this container")
        return _UNAVAILABLE
    except Exception:  # the contract is "never raise"
        logger.warning("cover text pass failed; falling through", exc_info=True)
        return _EMPTY


# The sweep order for a read that found nothing upright. Spines and sideways
# phone photos are the common cases, so quarter-turns; 180 last (rarest).
# ⚖️ Upright is ALWAYS read first and a usable upright read is returned
# without trying any rotation — the sweep can only add reads for images the
# upright pass scored at zero, so it cannot regress the measured upright
# hit rate (the same argument local_isbn_scan's transform sweep makes).
_ROTATION_SWEEP = (90, 270, 180)


def _read(image_bytes: bytes) -> CoverText:
    import pytesseract
    from PIL import Image

    with Image.open(io.BytesIO(image_bytes)) as im:
        # Greyscale only. Tesseract does its own thresholding, and anything
        # more here is a preprocessing choice that should be measured before
        # it is adopted rather than assumed to help.
        grey = im.convert("L")
        data = pytesseract.image_to_data(
            grey,
            output_type=pytesseract.Output.DICT,
        )

        words = _usable_words(data)

        if not words:
            # Rotation-aware: a spine or a sideways photo reads as nothing
            # upright. `expand=True` so a quarter-turn keeps every pixel.
            for angle in _ROTATION_SWEEP:
                rotated = grey.rotate(angle, expand=True)
                data = pytesseract.image_to_data(
                    rotated,
                    output_type=pytesseract.Output.DICT,
                )
                words = _usable_words(data)
                if words:
                    break

    if not words:
        return _EMPTY

    raw_text = " ".join(w["text"] for w in words)
    confidence = sum(w["conf"] for w in words) / len(words) / 100.0

    return CoverText(
        title=_title_from(words),
        author=_author_from(words),
        raw_text=raw_text,
        confidence=round(confidence, 3),
    )


def _usable_words(data: dict[str, Any]) -> list[_Word]:
    """Words the engine scored well enough to be worth reading."""
    out: list[_Word] = []
    for text, conf, height in zip(
        data.get("text", []),
        data.get("conf", []),
        data.get("height", []),
        strict=False,
    ):
        cleaned = text.strip()
        if len(cleaned) < _MIN_WORD_CHARS:
            continue
        try:
            score = float(conf)
        except (TypeError, ValueError):
            continue
        if score < _MIN_WORD_CONF:
            continue
        out.append(_Word(text=cleaned, conf=score, height=float(height or 0)))
    return out


def _title_from(words: list[_Word]) -> str | None:
    """The largest-set run of words, which on a cover is the title.

    ⚠️ This is a HEURISTIC and will be wrong on covers where the author's name
    is set larger than the title, which is common for a famous author. That
    failure mode is why the eval corpus has a hostile-typography stratum, and
    why this returns the author separately rather than guessing once.
    """
    tallest = max((w["height"] for w in words), default=0.0)
    if tallest <= 0:
        return None

    kept = [w["text"] for w in words if w["height"] >= tallest * _TITLE_HEIGHT_RATIO]
    if not kept:
        return None

    # Collapse the spacing artefacts of letter-spaced display type.
    title = re.sub(r"\s+", " ", " ".join(kept)).strip(_EDGE_PUNCT)
    return _strip_furniture(title)


def _strip_furniture(title: str) -> str | None:
    """Remove publisher furniture phrases, keeping the title's own words.

    ⬛ Whole phrases only. Removing a phrase can empty the title — a cover
    reading just "A NOVEL" in its largest type has no title in it — and an
    empty result is reported as a miss rather than as the empty string.
    """
    out = title
    for phrase in _FURNITURE_PHRASES:
        out = re.sub(rf"\b{re.escape(phrase)}\b", " ", out, flags=re.IGNORECASE)
    out = re.sub(r"\s+", " ", out).strip(_EDGE_PUNCT)

    # One pass, so a title ending in two tags keeps the second: anything that
    # repetitive is noise the eval should see rather than a cleanup to chase.
    for word in _TRAILING_FURNITURE:
        stripped = re.sub(rf"\s*\b{re.escape(word)}\b\s*$", "", out, flags=re.IGNORECASE)
        if stripped != out:
            out = stripped.strip(_EDGE_PUNCT)
            break

    return out or None


def _author_from(words: list[_Word]) -> str | None:
    """Words following an explicit `by`, when the cover sets one.

    ⬛ Deliberately narrow. Inferring an author from position ("the smallest
    text at the bottom") is wrong often enough on real covers that a confident
    wrong author is worse than none — the platform's title search accepts a
    nil author and simply searches on the title.
    """
    lowered = [w["text"].casefold().strip(".,:;") for w in words]
    try:
        marker = lowered.index("by")
    except ValueError:
        return None

    following = [w["text"] for w in words[marker + 1 : marker + 5]]
    if not following:
        return None
    return " ".join(following).strip(_EDGE_PUNCT) or None
