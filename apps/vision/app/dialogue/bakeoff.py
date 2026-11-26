"""The local-vs-hosted bake-off decision for the dialogue model.

The golden set is run through BOTH a LOCAL candidate (a small model served on the
scale-to-zero GPU) and a HOSTED reference (the Together API), and the choice is
made by the numbers, never assumed: local is the default and SHIPS if it clears
the per-dimension bar on every dimension; otherwise the hosted API is the
recorded fallback. Cost-per-session is carried alongside so the decision is
justified against spend, not only quality.

The scores and costs come from an owner-run measurement (generate the golden
turns on each provider, score them with the assistant eval); this module is the
decision rule over those numbers, unit-tested so 'justified by numbers' is a
property of the code and not a line in a report.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class ProviderResult:
    provider: str
    per_dimension: dict[str, float]
    cost_per_session_micro_cents: int


@dataclass
class BakeoffChoice:
    provider: str
    justification: list[str]


def shortfalls(result: ProviderResult, bar: dict[str, float]) -> list[str]:
    """Dimensions where the provider scored below the bar, in bar order."""
    return [dim for dim, floor in bar.items() if result.per_dimension.get(dim, 0.0) < floor]


def choose(local: ProviderResult, hosted: ProviderResult, bar: dict[str, float]) -> BakeoffChoice:
    """Local ships if it clears the bar on EVERY dimension; otherwise the hosted
    reference is the recorded fallback. The justification names the deciding
    dimensions and the cost-per-session delta."""
    local_short = shortfalls(local, bar)

    if not local_short:
        justification = ["local cleared every per-dimension bar"]
        delta = hosted.cost_per_session_micro_cents - local.cost_per_session_micro_cents
        justification.append(
            f"cost/session: local {local.cost_per_session_micro_cents} vs hosted "
            f"{hosted.cost_per_session_micro_cents} micro-cents (local saves {delta})"
        )
        return BakeoffChoice("local", justification)

    return BakeoffChoice(
        "hosted",
        [f"local fell short on {', '.join(local_short)}; hosted is the recorded fallback"],
    )
