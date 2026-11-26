"""The local-vs-hosted bake-off decision: local ships only if it clears the
per-dimension bar, otherwise the hosted reference is the recorded fallback, and
the choice carries its cost-per-session justification.
"""

from app.dialogue.bakeoff import ProviderResult, choose, shortfalls

_BAR = {"faithfulness": 0.9, "verbatim_safety": 1.0, "refusal": 0.8}


def _local(per_dimension: dict[str, float], cost: int = 500) -> ProviderResult:
    return ProviderResult("local", per_dimension, cost)


def _hosted(cost: int = 2000) -> ProviderResult:
    return ProviderResult(
        "hosted", {"faithfulness": 0.95, "verbatim_safety": 1.0, "refusal": 0.9}, cost
    )


def test_shortfalls_lists_below_bar_dimensions() -> None:
    result = _local({"faithfulness": 0.85, "verbatim_safety": 1.0, "refusal": 0.7})
    assert shortfalls(result, _BAR) == ["faithfulness", "refusal"]


def test_local_ships_when_it_clears_every_bar() -> None:
    local = _local({"faithfulness": 0.92, "verbatim_safety": 1.0, "refusal": 0.85})
    choice = choose(local, _hosted(), _BAR)

    assert choice.provider == "local"
    assert any("saves 1500" in line for line in choice.justification)


def test_hosted_is_the_fallback_when_local_falls_short() -> None:
    local = _local({"faithfulness": 0.88, "verbatim_safety": 1.0, "refusal": 0.85})
    choice = choose(local, _hosted(), _BAR)

    assert choice.provider == "hosted"
    assert any("faithfulness" in line for line in choice.justification)


def test_a_missing_dimension_counts_as_a_shortfall() -> None:
    local = _local({"verbatim_safety": 1.0, "refusal": 0.85})  # faithfulness absent
    assert choose(local, _hosted(), _BAR).provider == "hosted"
