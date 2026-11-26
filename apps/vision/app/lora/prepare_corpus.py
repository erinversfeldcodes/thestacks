"""Corpus preparation for a LoRA fine-tune on the author's writing.

Turns the author's own documents into training sequences with the research's
anti-memorisation mitigations applied up front: near-duplicate DEDUP (a repeated
passage is the single sharpest driver of verbatim recall) and a small set of
planted CANARIES whose later recall the privacy ship-gate measures. Few epochs,
low rank and dropout live in the training config; dedup and canaries live here.

The input is the author's text -- already extracted from their files by the
vision document extractor; nothing here touches the database. The output (the
training sequences and the list of planted canaries) is a sensitive artifact
handled at the corpus's data classification, and is never committed.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass

_WORD = re.compile(r"[a-z0-9]+")


def _tokens(text: str) -> list[str]:
    return _WORD.findall(text.lower())


def _shingles(text: str, k: int = 5) -> set[str]:
    toks = _tokens(text)
    if len(toks) < k:
        return {" ".join(toks)} if toks else set()
    return {" ".join(toks[i : i + k]) for i in range(len(toks) - k + 1)}


def _jaccard(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    union = len(a | b)
    return len(a & b) / union if union else 0.0


def near_dup_dedup(texts: list[str], threshold: float = 0.8) -> list[str]:
    """Keep texts in order, dropping any whose 5-shingle Jaccard with an
    already-kept text exceeds `threshold`. Near-duplication is the sharpest
    driver of verbatim memorisation, so this runs before training, not after."""
    kept: list[str] = []
    kept_shingles: list[set[str]] = []
    for text in texts:
        shing = _shingles(text)
        if any(_jaccard(shing, seen) > threshold for seen in kept_shingles):
            continue
        kept.append(text)
        kept_shingles.append(shing)
    return kept


def chunk_for_training(text: str, max_chars: int = 2000) -> list[str]:
    """Split a document into training sequences at paragraph boundaries, packing
    up to `max_chars` per sequence so one rarely spans unrelated sections."""
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    chunks: list[str] = []
    buf = ""
    for para in paragraphs:
        if buf and len(buf) + len(para) + 2 > max_chars:
            chunks.append(buf)
            buf = para
        else:
            buf = f"{buf}\n\n{para}" if buf else para
    if buf:
        chunks.append(buf)
    return chunks


def make_canaries(count: int, seed: int = 0) -> list[str]:
    """Deterministic, unique canary strings to plant in the training data. Each
    is a rare marker the privacy ship-gate later checks the model does not
    reproduce from a prefix."""
    canaries = []
    for i in range(count):
        digest = hashlib.sha256(f"canary-{seed}-{i}".encode()).hexdigest()[:16]
        canaries.append(f"canary {digest} marker")
    return canaries


@dataclass
class PreparedCorpus:
    sequences: list[str]
    canaries: list[str]


def prepare(
    documents: list[str],
    *,
    dedup_threshold: float = 0.8,
    max_chars: int = 2000,
    canary_count: int = 8,
    canary_repeats: int = 16,
    seed: int = 0,
) -> PreparedCorpus:
    """The full prep: dedup the documents, chunk them into training sequences,
    and plant `canary_count` canaries each repeated `canary_repeats` times. The
    research's 16-rep level is the memorisation threshold the ship-gate must
    prove safe, so planting at it makes the gate's canary check meaningful."""
    deduped = near_dup_dedup(documents, dedup_threshold)
    sequences: list[str] = []
    for doc in deduped:
        sequences.extend(chunk_for_training(doc, max_chars))
    canaries = make_canaries(canary_count, seed)
    for canary in canaries:
        sequences.extend([canary] * canary_repeats)
    return PreparedCorpus(sequences=sequences, canaries=canaries)
