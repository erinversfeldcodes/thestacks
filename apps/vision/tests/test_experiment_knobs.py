"""The knobs an experiment varies, and the defaults it must not disturb.

⛔ A BASELINE STOPS BEING ONE THE MOMENT ITS DEFAULT MOVES. These knobs exist
so that trying a T4, a smaller model, int8 or a pixel cap is a DEPLOY rather
than a source edit — which only works if an unparameterised deploy behaves
exactly as the measured baseline did. Every default here is the literal that
was deployed when the 122-image corpus was scored.
"""

from __future__ import annotations

import importlib
import os
from unittest.mock import patch

import pytest


def _reload():
    import modal_app

    return importlib.reload(modal_app)


class TestDefaultsAreTheMeasuredBaseline:
    @pytest.mark.parametrize(
        ("attr", "expected"),
        [
            ("MODEL_NAME", "Qwen/Qwen3-VL-4B-Instruct"),
            ("VISION_GPU", "T4"),
            ("VISION_DTYPE", "float16"),
        ],
    )
    def test_an_unset_knob_keeps_the_measured_value(self, attr: str, expected: str) -> None:
        with patch.dict(os.environ, {}, clear=False):
            for key in ("VISION_MODEL_NAME", "VISION_GPU", "VISION_DTYPE"):
                os.environ.pop(key, None)
            mod = _reload()

        assert getattr(mod, attr) == expected, (
            f"{attr} drifted from the ruled production architecture (T4 + "
            "Qwen3-VL-4B fp16, the measured 84/122 configuration, owner-accepted "
            "2026-11-17). Moving a default is an architecture decision with its "
            "own eval baseline, never a drive-by edit — the previous move, off "
            "the 7B/A10G baseline, carried a ruling and a re-recorded baseline."
        )

    # ⚠️ None, NOT a number. An explicit value would override the processor's
    # own default, and the baseline ran on that default — so "unset" has to stay
    # distinguishable from "set to whatever we guessed the default was".
    def test_max_pixels_defaults_to_the_processors_own(self) -> None:
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("VISION_MAX_PIXELS", None)
            mod = _reload()

        assert mod.VISION_MAX_PIXELS is None, (
            "an explicit pixel cap is a different experiment from the baseline, "
            f"got {mod.VISION_MAX_PIXELS!r}"
        )


class TestEachKnobActuallyMoves:
    """⬛ ANTI-VACUITY for the block above: defaults that cannot be overridden
    would pass every test there while making the experiments impossible."""

    @pytest.mark.parametrize(
        ("env", "attr", "value"),
        [
            ("VISION_GPU", "VISION_GPU", "T4"),
            ("VISION_DTYPE", "VISION_DTYPE", "int8"),
            ("VISION_MODEL_NAME", "MODEL_NAME", "Qwen/Qwen3-VL-4B-Instruct"),
        ],
    )
    def test_the_environment_wins(self, env: str, attr: str, value: str) -> None:
        with patch.dict(os.environ, {env: value}):
            mod = _reload()
        assert getattr(mod, attr) == value

    def test_max_pixels_parses_as_an_integer(self) -> None:
        with patch.dict(os.environ, {"VISION_MAX_PIXELS": "1003520"}):
            mod = _reload()
        assert mod.VISION_MAX_PIXELS == 1_003_520, (
            "the processor wants an int; a string here would be a silent type "
            "error at load time on a GPU container, which is the most expensive "
            "place to discover one"
        )


class TestContainerReResolution:
    """⛔ THE DEFECT CLASS: Modal re-imports this module in the build and
    runtime containers, where the VISION_* env vars never existed — so any
    knob read inside a function body silently reverts to its default there.
    The fix bakes set knobs into the image env. These tests hold the two
    halves of that fix in place."""

    def test_set_knobs_are_captured_for_the_image_env(self) -> None:
        with patch.dict(
            os.environ,
            {"VISION_MAX_PIXELS": "1003520", "VISION_DTYPE": "float16"},
        ):
            mod = _reload()

        plan = mod._image_plan()
        assert ("env", {"VISION_MAX_PIXELS": "1003520", "VISION_DTYPE": "float16"}) in plan, (
            "a knob that is set locally but not baked into the image env "
            "re-resolves to its default inside the container — the deploy "
            "then runs a byte-identical copy of the baseline and reports it "
            "as a variant"
        )
        # ⬛ Order inside the plan is load-bearing: env before the weight bake,
        # or the build container downloads the DEFAULT model into a variant.
        assert plan.index(
            ("env", {"VISION_MAX_PIXELS": "1003520", "VISION_DTYPE": "float16"})
        ) < plan.index(("run_function", "_download_model"))

    # ⬛ ANTI-VACUITY + the hash guarantee: with nothing set, nothing may be
    # baked, or the default image hash moves and the baseline stops being one.
    def test_unset_knobs_bake_nothing(self) -> None:
        with patch.dict(os.environ, {}, clear=False):
            for key in (
                "VISION_MODEL_NAME",
                "VISION_DTYPE",
                "VISION_MAX_PIXELS",
                "VISION_EXTRA_PIPS",
            ):
                os.environ.pop(key, None)
            mod = _reload()

        assert mod._image_plan() == [("run_function", "_download_model")], (
            "with nothing set the plan must add no layer at all, or the "
            "default image hash moves and the baseline stops being a baseline"
        )

    def test_extra_pips_split_and_strip(self) -> None:
        with patch.dict(os.environ, {"VISION_EXTRA_PIPS": "autoawq, transformers>=4.57.0"}):
            mod = _reload()
        assert mod._EXTRA_PIPS == ["autoawq", "transformers>=4.57.0"]


class TestModelClassSelection:
    @pytest.mark.parametrize(
        ("model", "cls"),
        [
            ("Qwen/Qwen2.5-VL-7B-Instruct", "Qwen2_5_VLForConditionalGeneration"),
            # ⚖️ An AWQ checkpoint of 2.5-VL is still a 2.5-VL: its
            # quantisation rides in the checkpoint config, not the loader.
            ("Qwen/Qwen2.5-VL-7B-Instruct-AWQ", "Qwen2_5_VLForConditionalGeneration"),
            ("Qwen/Qwen3-VL-4B-Instruct", "Qwen3VLForConditionalGeneration"),
            ("Qwen/Qwen3-VL-2B-Instruct", "Qwen3VLForConditionalGeneration"),
        ],
    )
    def test_each_family_gets_its_class(self, model: str, cls: str) -> None:
        mod = _reload()
        assert mod._model_class_name(model) == cls
