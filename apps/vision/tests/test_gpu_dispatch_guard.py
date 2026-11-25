"""The per-value type guard in `_gpu_dispatch`.

⛔ WHY THIS EXISTS. `_gpu_dispatch` reads a container's self-report across a
process boundary from a SEPARATELY deployed GPU image, so "it is a dict" says
nothing about what is inside it. The guard type-checks each value individually.
It had no test: a probe loosening it to
`GpuDispatch(cold=bool(cold), container_id=str(cid))` left 119 tests green — and
that loosening would turn `{"cold": "yes", "container_id": None}` into a
fabricated warm dispatch on a container literally named "None", feeding a
cost model that bills per container lifetime. Each case below reds under it.
"""

from __future__ import annotations

from app.main import _gpu_dispatch


def test_valid_container_reading_becomes_a_dispatch() -> None:
    d = _gpu_dispatch({"_container": {"cold": True, "container_id": "abc"}})
    assert d is not None
    assert d.cold is True
    assert d.container_id == "abc"


def test_absent_or_non_dict_container_is_no_reading() -> None:
    assert _gpu_dispatch({}) is None
    assert _gpu_dispatch({"_container": "not-a-dict"}) is None
    assert _gpu_dispatch({"_container": None}) is None


def test_non_bool_cold_is_rejected_not_coerced() -> None:
    # `bool("yes")` is True — a coercing guard would fabricate a cold/warm flag
    # from a string the image never meant as a boolean.
    assert _gpu_dispatch({"_container": {"cold": "yes", "container_id": "abc"}}) is None
    assert _gpu_dispatch({"_container": {"cold": 1, "container_id": "abc"}}) is None


def test_non_str_or_empty_container_id_is_rejected_not_coerced() -> None:
    # `str(None)` is "None" — a coercing guard would fabricate a container id,
    # and "" is the "no reading" sentinel, not a real container.
    assert _gpu_dispatch({"_container": {"cold": True, "container_id": None}}) is None
    assert _gpu_dispatch({"_container": {"cold": True, "container_id": ""}}) is None
