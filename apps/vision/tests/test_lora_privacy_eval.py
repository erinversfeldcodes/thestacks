"""The LoRA privacy ship-gate: the three vetoes that keep a corpus-trained
adapter from reciting the author's writing. Each veto is exercised on its own so
a neutered veto reds its test; `ship_decision` is the single ship authority.
"""

from app.lora.privacy_eval import (
    ShipThresholds,
    canary_leak_rate,
    canary_reproduced,
    extraction_overlap,
    longest_common_run,
    mia_auc,
    ship_decision,
)


def test_canary_reproduced_detects_verbatim_recall() -> None:
    assert canary_reproduced("the secret phrase is BLUE-WIDGET-42 you see", "blue widget 42")
    assert not canary_reproduced("nothing memorised here at all", "blue widget 42")


def test_canary_leak_rate_is_the_reproduced_fraction() -> None:
    generations = ["it said ZX99 clearly", "a clean answer", "then QQ7 appeared"]
    canaries = ["zx99", "absent-marker", "qq7"]
    assert canary_leak_rate(generations, canaries) == 2 / 3
    assert canary_leak_rate([], []) == 0.0


def test_longest_common_run_and_extraction_overlap() -> None:
    true = " ".join(f"w{i}" for i in range(60))
    assert extraction_overlap("prefix " + true + " suffix", true) >= 50
    assert extraction_overlap("an entirely unrelated continuation of prose", true) < 8
    assert longest_common_run([], ["a"]) == 0


def test_mia_auc_rises_with_memorisation_and_sits_at_chance_otherwise() -> None:
    # Members (training rows) memorised -> far lower loss -> AUC near 1.0.
    assert mia_auc([0.1, 0.2, 0.15], [0.9, 0.85, 0.95]) > 0.9
    # Indistinguishable losses -> chance.
    assert abs(mia_auc([0.5, 0.5], [0.5, 0.5]) - 0.5) < 1e-9
    # No evidence either way.
    assert mia_auc([], [0.5]) == 0.5


def test_ship_decision_ships_only_when_every_veto_is_clear() -> None:
    clear = ship_decision(0.0, [10, 20], 0.52)
    assert clear.ship
    assert clear.reasons == []


def test_each_veto_blocks_the_ship() -> None:
    assert not ship_decision(0.1, [0], 0.5).ship  # a canary leaked
    assert not ship_decision(0.0, [55], 0.5).ship  # a 55-token run extracted
    assert not ship_decision(0.0, [0], 0.9).ship  # MIA well above chance


def test_all_three_vetoes_are_reported_together() -> None:
    decision = ship_decision(0.5, [60], 0.95)
    assert not decision.ship
    assert len(decision.reasons) == 3


def test_thresholds_are_configurable() -> None:
    lax = ShipThresholds(max_mia_auc=0.99)
    assert ship_decision(0.0, [0], 0.9, lax).ship
