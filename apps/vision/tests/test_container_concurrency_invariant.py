"""The single-input-per-container invariant that `container_dispatch`'s cold
count depends on.

`cold = inferences_since_load == 0` is correct ONLY if each GPU container
processes its inputs serially. `@modal.concurrent` (or `allow_concurrent_inputs`
on `@app.cls`) would let a second input ride a warm container the counter had
not yet credited, under-counting cold starts — the flattering direction. The
module docstring states the invariant; this enforces it.

⛔ Via the AST, not a text grep: `modal_app.py` carries a comment about the Oban
queue running "at concurrency 20", so a substring search would false-positive on
prose. The AST sees only the decorators.
"""

from __future__ import annotations

import ast
import pathlib

_SRC = pathlib.Path(__file__).resolve().parents[1] / "modal_app.py"


def _vision_model_classdef() -> ast.ClassDef:
    tree = ast.parse(_SRC.read_text())
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name == "VisionModel":
            return node
    raise AssertionError("VisionModel class not found in modal_app.py")


def _is_modal_concurrent(dec: ast.expr) -> bool:
    target = dec.func if isinstance(dec, ast.Call) else dec
    return isinstance(target, ast.Attribute) and target.attr == "concurrent"


def test_app_cls_does_not_enable_concurrent_inputs() -> None:
    cls = _vision_model_classdef()
    for dec in cls.decorator_list:
        if isinstance(dec, ast.Call):
            kws = {kw.arg for kw in dec.keywords if kw.arg}
            assert "allow_concurrent_inputs" not in kws, (
                "VisionModel enables concurrent inputs — breaks container_dispatch's "
                "one-inference-per-container cold count"
            )
        assert not _is_modal_concurrent(dec), "VisionModel is decorated @modal.concurrent"


def test_no_vision_model_method_is_modal_concurrent() -> None:
    cls = _vision_model_classdef()
    for item in cls.body:
        if isinstance(item, ast.FunctionDef | ast.AsyncFunctionDef):
            for dec in item.decorator_list:
                assert not _is_modal_concurrent(dec), (
                    f"{item.name} is @modal.concurrent — breaks the serial cold count"
                )
