"""Corpus preparation for the LoRA fine-tune: near-duplicate dedup (the sharpest
memorisation driver), paragraph-packing into training sequences, and canary
planting at the research's repeat threshold so the ship-gate's canary check bites.
"""

from app.lora.prepare_corpus import (
    chunk_for_training,
    make_canaries,
    near_dup_dedup,
    prepare,
)

_A = "the quick brown fox jumps over the lazy dog near the river bank at dawn"
_A_NEAR = _A + " indeed"  # one extra token -> ~0.92 Jaccard with _A
_B = "a completely different sentence about something else entirely unrelated here now"


def test_near_dup_dedup_drops_a_near_duplicate_keeps_distinct() -> None:
    kept = near_dup_dedup([_A, _A_NEAR, _B], threshold=0.8)
    assert kept == [_A, _B]


def test_near_dup_dedup_keeps_all_when_distinct() -> None:
    assert near_dup_dedup([_A, _B], threshold=0.8) == [_A, _B]


def test_chunk_for_training_packs_paragraphs_to_the_limit() -> None:
    text = "para one text\n\npara two text\n\npara three text"
    chunks = chunk_for_training(text, max_chars=15)
    assert chunks == ["para one text", "para two text", "para three text"]


def test_chunk_for_training_packs_several_small_paragraphs_together() -> None:
    text = "aa\n\nbb\n\ncc"
    assert chunk_for_training(text, max_chars=100) == ["aa\n\nbb\n\ncc"]


def test_make_canaries_are_deterministic_and_unique() -> None:
    canaries = make_canaries(5, seed=1)
    assert len(canaries) == 5
    assert len(set(canaries)) == 5
    assert make_canaries(5, seed=1) == canaries


def test_prepare_dedups_then_plants_canaries_at_the_repeat_count() -> None:
    result = prepare(
        [_A, _A_NEAR, _B],
        dedup_threshold=0.8,
        max_chars=2000,
        canary_count=2,
        canary_repeats=16,
        seed=0,
    )

    assert len(result.canaries) == 2
    # Each canary is planted exactly `canary_repeats` times.
    for canary in result.canaries:
        assert result.sequences.count(canary) == 16
    # The near-duplicate document did not reach the sequences.
    assert not any(_A_NEAR in seq for seq in result.sequences if seq not in result.canaries)
