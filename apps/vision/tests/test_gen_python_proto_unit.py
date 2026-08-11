"""Unit tests for scripts/gen_python_proto.py internals.

Focuses on _get_real_oneof_groups, which determines whether a proto oneof block
is synthetic (created by proto3 optional) or real. This distinction drives
whether Pydantic validators are generated.
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from gen_python_proto import _get_real_oneof_groups  # noqa: E402


def _make_field(name: str, oneof_index: int, proto3_optional: bool = False) -> dict[str, object]:
    f: dict[str, object] = {"name": name, "oneofIndex": oneof_index}
    if proto3_optional:
        f["proto3Optional"] = True
    return f


def _make_msg(oneof_names: list[str], fields: list[dict[str, object]]) -> dict[str, object]:
    return {
        "oneofDecl": [{"name": n} for n in oneof_names],
        "field": fields,
    }


def test_real_oneof_is_included() -> None:
    """A real oneof block (no proto3Optional fields) is returned."""
    msg = _make_msg(
        oneof_names=["image_source"],
        fields=[
            _make_field("image", oneof_index=0),
            _make_field("image_url", oneof_index=0),
        ],
    )
    groups = _get_real_oneof_groups(msg)
    assert 0 in groups
    name, field_names = groups[0]
    assert name == "image_source"
    assert set(field_names) == {"image", "image_url"}


def test_synthetic_oneof_is_excluded() -> None:
    """A synthetic oneof (proto3 optional field) is excluded.

    When a field has proto3Optional=true, its oneof index refers to a synthetic
    oneof created by protoc — not a developer-written oneof block. The canonical
    signal is proto3Optional on the field, per the protobuf spec.
    """
    msg = _make_msg(
        oneof_names=["_cover_image_url"],
        fields=[
            _make_field("cover_image_url", oneof_index=0, proto3_optional=True),
        ],
    )
    groups = _get_real_oneof_groups(msg)
    assert groups == {}


def test_mixed_real_and_synthetic_oneofs() -> None:
    """Real and synthetic oneofs coexist in the same message correctly."""
    msg = _make_msg(
        oneof_names=["image_source", "_reason"],
        fields=[
            _make_field("image", oneof_index=0),
            _make_field("image_url", oneof_index=0),
            _make_field("reason", oneof_index=1, proto3_optional=True),
        ],
    )
    groups = _get_real_oneof_groups(msg)
    assert 0 in groups
    assert 1 not in groups
    _, field_names = groups[0]
    assert set(field_names) == {"image", "image_url"}


def test_message_with_no_oneofs() -> None:
    """Message with no oneof blocks returns empty dict."""
    msg = _make_msg(
        oneof_names=[],
        fields=[_make_field("isbn", oneof_index=0) if False else {"name": "isbn"}],
    )
    groups = _get_real_oneof_groups(msg)
    assert groups == {}


def test_real_oneof_name_starting_with_underscore() -> None:
    """A real oneof whose name starts with '_' is NOT excluded.

    The old implementation (name.startswith('_')) would have incorrectly excluded
    this. The proto3Optional flag is the correct signal, not the name prefix.
    """
    msg = _make_msg(
        oneof_names=["_real_oneof"],
        fields=[
            _make_field("option_a", oneof_index=0),
            _make_field("option_b", oneof_index=0),
        ],
    )
    groups = _get_real_oneof_groups(msg)
    assert 0 in groups
    _, field_names = groups[0]
    assert set(field_names) == {"option_a", "option_b"}
