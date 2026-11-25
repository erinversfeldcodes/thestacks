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

NOTE: `allow_concurrent_inputs` is no longer a valid `@app.cls` kwarg in the
pinned Modal (it is rejected at definition time), so the class-kwarg half is
defence-in-depth against a Modal downgrade. The live guard is
`@modal.concurrent` on a method — `test_no_vision_model_method_is_modal_concurrent`.
"""

from __future__ import annotations

import ast
import pathlib

_SRC = pathlib.Path(__file__).resolve().parents[1] / "modal_app.py"

# Any kwarg that would let one container take a second input before the cold
# counter has credited the first.
_CONCURRENCY_KEYS = frozenset({"allow_concurrent_inputs", "max_concurrent_inputs", "concurrency"})


def _vision_model_classdef() -> ast.ClassDef:
    tree = ast.parse(_SRC.read_text())
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name == "VisionModel":
            return node
    raise AssertionError("VisionModel class not found in modal_app.py")


def _is_modal_concurrent(dec: ast.expr) -> bool:
    target = dec.func if isinstance(dec, ast.Call) else dec
    # `@modal.concurrent` is an Attribute; a bare `@concurrent` from
    # `from modal import concurrent` is a Name. Match both, so an import
    # refactor cannot slip the decorator past this guard.
    if isinstance(target, ast.Attribute):
        return target.attr == "concurrent"
    if isinstance(target, ast.Name):
        return target.id == "concurrent"
    return False


def _cls_kwargs_keys() -> set[str]:
    """Every string key written into the module-level `_cls_kwargs` dict.

    `@app.cls(**_cls_kwargs)` unpacks the dict, and a `**` unpack has `kw.arg is
    None`, so it is invisible to the keyword scan in `test_app_cls_...`. A
    concurrency key hidden in `_cls_kwargs` would slip past. `_cls_kwargs` is
    built by subscript assignment (`_cls_kwargs["enable_memory_snapshot"] =
    ...`), not as a dict literal, so BOTH forms are read here — a literal-only
    reader would see the empty `= {}` and pass vacuously.
    """
    tree = ast.parse(_SRC.read_text())
    keys: set[str] = set()

    def _literal_keys(node: ast.Dict) -> set[str]:
        return {
            k.value for k in node.keys if isinstance(k, ast.Constant) and isinstance(k.value, str)
        }

    for node in ast.walk(tree):
        # `_cls_kwargs: dict[...] = { ... }`
        if (
            isinstance(node, ast.AnnAssign)
            and isinstance(node.target, ast.Name)
            and node.target.id == "_cls_kwargs"
            and isinstance(node.value, ast.Dict)
        ):
            keys |= _literal_keys(node.value)
        if isinstance(node, ast.Assign):
            for tgt in node.targets:
                # `_cls_kwargs = { ... }`
                if (
                    isinstance(tgt, ast.Name)
                    and tgt.id == "_cls_kwargs"
                    and isinstance(node.value, ast.Dict)
                ):
                    keys |= _literal_keys(node.value)
                # `_cls_kwargs["key"] = ...`
                if (
                    isinstance(tgt, ast.Subscript)
                    and isinstance(tgt.value, ast.Name)
                    and tgt.value.id == "_cls_kwargs"
                    and isinstance(tgt.slice, ast.Constant)
                    and isinstance(tgt.slice.value, str)
                ):
                    keys.add(tgt.slice.value)
    return keys


def test_app_cls_does_not_enable_concurrent_inputs() -> None:
    cls = _vision_model_classdef()
    for dec in cls.decorator_list:
        if isinstance(dec, ast.Call):
            kws = {kw.arg for kw in dec.keywords if kw.arg}
            assert not (_CONCURRENCY_KEYS & kws), (
                "VisionModel enables concurrent inputs — breaks container_dispatch's "
                "one-inference-per-container cold count"
            )
        assert not _is_modal_concurrent(dec), "VisionModel is decorated @modal.concurrent"
    # The `**_cls_kwargs` unpack is invisible to the scan above (its arg is None),
    # so check the unpacked dict's own keys.
    assert not (_CONCURRENCY_KEYS & _cls_kwargs_keys()), (
        "a concurrency kwarg is hidden in _cls_kwargs, unpacked into @app.cls — "
        "breaks the one-inference-per-container cold count"
    )


def test_cls_kwargs_scan_sees_real_keys() -> None:
    # Anti-vacuity: the _cls_kwargs scan must actually observe the keys the
    # module writes, or the guard above passes for the wrong reason.
    assert "enable_memory_snapshot" in _cls_kwargs_keys()


def test_no_vision_model_method_is_modal_concurrent() -> None:
    cls = _vision_model_classdef()
    for item in cls.body:
        if isinstance(item, ast.FunctionDef | ast.AsyncFunctionDef):
            for dec in item.decorator_list:
                assert not _is_modal_concurrent(dec), (
                    f"{item.name} is @modal.concurrent — breaks the serial cold count"
                )
