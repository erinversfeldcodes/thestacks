"""The GPU cold-start reading's PRODUCER, which had no test that could fail.

⛔ WHY THIS FILE EXISTS. Every test in `test_analyze.py` mocks
`VisionClient.classify`/`extract` wholesale, so `_container` arrives
ready-made and nothing exercises the rule that decides `cold`. A review probe
hard-coded `gpu_cold = False` in `modal_app.py` and the suite stayed at
119 passed / 0 failed — the reading the entire idle-GPU costing is derived
from was unguarded. `modal_app.py` is also outside `scripts/lint-python.sh`,
which runs `mypy app/`, so neither gate saw it.

⚖️ The rule is tested through `container_dispatch`, a module-level function,
because `VisionModel` is wrapped by `@app.cls()` into a Modal `Cls` object
rather than a plain type — `VisionModel.__new__` raises
`TypeError: X is not a type object`, so the method could not be driven
directly. Extracting the arithmetic is the fix for "the producer is
untestable", not a way around it.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from modal_app import container_dispatch


def test_a_container_that_has_answered_nothing_is_cold() -> None:
    d = container_dispatch(0, "deadbeef")
    assert d["cold"] is True, (
        "a container's first answer is its cold start; if this is False the idle-GPU "
        "line loses the 300s container lifetime it prices"
    )
    assert d["container_id"] == "deadbeef"


def test_a_container_that_has_already_answered_is_warm() -> None:
    assert container_dispatch(1, "deadbeef")["cold"] is False, (
        "a second answer from the same container is warm — reporting it cold would "
        "multiply the billed lifetimes the idle cost is summed from"
    )


def test_the_count_not_a_boolean_decides_it() -> None:
    """⛔ ANTI-VACUITY: distinguishes the real rule from a hard-coded answer.

    A probe that returns a constant satisfies either of the two cases above on
    its own. Driving several counts in one assertion means `cold` must track
    the argument rather than merely agreeing with one expectation.
    """
    seen = [container_dispatch(n, "c")["cold"] for n in (0, 1, 2, 7)]
    assert seen == [True, False, False, False], (
        f"cold must follow the count, not a constant; got {seen}"
    )


def test_the_container_id_is_carried_through_unchanged() -> None:
    # ⚖️ Asserted because the id is what `GpuWindow.cold_container_count/1`
    # groups by: two dispatches sharing an id are ONE woken container, and a
    # mangled or defaulted id would silently split them into two.
    assert container_dispatch(0, "9f8e7d")["container_id"] == "9f8e7d"
