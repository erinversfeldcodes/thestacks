#!/usr/bin/env python3
"""
Generate typed models from proto definitions via buf JSON descriptor.

Proto is the source of truth. All service types are generated, not hand-written.
Supports Python (Pydantic v2), Rust (serde structs), and Elixir (defstruct).

Usage:
    python3 scripts/gen_python_proto.py                    # generate all targets
    python3 scripts/gen_python_proto.py --language python  # generate Python only
    python3 scripts/gen_python_proto.py --check            # verify all; exit 1 on drift
    python3 scripts/gen_python_proto.py --language rust --check

Output files are gitignored and regenerated at build time.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PROTO_DIR = REPO_ROOT / "proto"

TARGETS: list[dict] = [
    {
        "proto_file": "stacks/internal/v1/vision.proto",
        "language": "python",
        "output": REPO_ROOT / "apps/vision/app/proto/gen/vision.py",
    },
    {
        "proto_file": "stacks/internal/v1/scraper.proto",
        "language": "rust",
        "output": REPO_ROOT / "apps/scraper/src/proto/generated/scraper.rs",
    },
    {
        "proto_file": "stacks/internal/v1/vision.proto",
        "language": "elixir",
        "output": REPO_ROOT / "apps/core/lib/stacks/gen/proto/vision.ex",
    },
    {
        "proto_file": "stacks/internal/v1/scraper.proto",
        "language": "elixir",
        "output": REPO_ROOT / "apps/core/lib/stacks/gen/proto/scraper.ex",
    },
]

# ---------------------------------------------------------------------------
# Proto type maps
# ---------------------------------------------------------------------------

PY_SCALAR_TYPES: dict[str, str] = {
    "TYPE_STRING": "str",
    "TYPE_BYTES": "bytes",
    "TYPE_BOOL": "bool",
    "TYPE_INT32": "int",
    "TYPE_INT64": "int",
    "TYPE_UINT32": "int",
    "TYPE_UINT64": "int",
    "TYPE_SINT32": "int",
    "TYPE_SINT64": "int",
    "TYPE_FIXED32": "int",
    "TYPE_FIXED64": "int",
    "TYPE_SFIXED32": "int",
    "TYPE_SFIXED64": "int",
    "TYPE_FLOAT": "float",
    "TYPE_DOUBLE": "float",
}

PY_WKT_TYPES: dict[str, str] = {
    ".google.protobuf.Timestamp": "datetime",
    ".google.protobuf.Struct": "dict[str, Any]",
    ".google.protobuf.StringValue": "str | None",
    ".google.protobuf.BoolValue": "bool | None",
    ".google.protobuf.Int32Value": "int | None",
    ".google.protobuf.Int64Value": "int | None",
    ".google.protobuf.FloatValue": "float | None",
    ".google.protobuf.DoubleValue": "float | None",
}

RS_SCALAR_TYPES: dict[str, str] = {
    "TYPE_STRING": "String",
    "TYPE_BYTES": "Vec<u8>",
    "TYPE_BOOL": "bool",
    "TYPE_INT32": "i32",
    "TYPE_INT64": "i64",
    "TYPE_UINT32": "u32",
    "TYPE_UINT64": "u64",
    "TYPE_SINT32": "i32",
    "TYPE_SINT64": "i64",
    "TYPE_FIXED32": "u32",
    "TYPE_FIXED64": "u64",
    "TYPE_SFIXED32": "i32",
    "TYPE_SFIXED64": "i64",
    "TYPE_FLOAT": "f32",
    "TYPE_DOUBLE": "f64",
}

RS_WKT_TYPES: dict[str, str] = {
    ".google.protobuf.Timestamp": "String",  # ISO-8601 as string on the wire
    ".google.protobuf.Struct": "serde_json::Value",
}

EX_SCALAR_TYPES: dict[str, str] = {
    "TYPE_STRING": "String.t()",
    "TYPE_BYTES": "binary()",
    "TYPE_BOOL": "boolean()",
    "TYPE_INT32": "integer()",
    "TYPE_INT64": "integer()",
    "TYPE_UINT32": "non_neg_integer()",
    "TYPE_UINT64": "non_neg_integer()",
    "TYPE_SINT32": "integer()",
    "TYPE_SINT64": "integer()",
    "TYPE_FIXED32": "non_neg_integer()",
    "TYPE_FIXED64": "non_neg_integer()",
    "TYPE_SFIXED32": "integer()",
    "TYPE_SFIXED64": "integer()",
    "TYPE_FLOAT": "float()",
    "TYPE_DOUBLE": "float()",
}

EX_WKT_TYPES: dict[str, str] = {
    ".google.protobuf.Timestamp": "DateTime.t()",
    ".google.protobuf.Struct": "map()",
}

# Proto3 zero values for non-optional Python field defaults.
# Matches Elixir/Rust: missing scalar fields on the wire default to zero, not a validation error.
PY_ZERO_VALUES: dict[str, str] = {
    "TYPE_STRING": '""',
    "TYPE_ENUM": '""',
    "TYPE_BYTES": 'b""',
    "TYPE_BOOL": "False",
    "TYPE_INT32": "0",
    "TYPE_INT64": "0",
    "TYPE_UINT32": "0",
    "TYPE_UINT64": "0",
    "TYPE_SINT32": "0",
    "TYPE_SINT64": "0",
    "TYPE_FIXED32": "0",
    "TYPE_FIXED64": "0",
    "TYPE_SFIXED32": "0",
    "TYPE_SFIXED64": "0",
    "TYPE_FLOAT": "0.0",
    "TYPE_DOUBLE": "0.0",
}

# Semantic mutual-exclusion rules that proto3 cannot express (e.g., repeated vs optional).
# Each entry is a dict with "method" (validator name), "check" (condition), "error" (message).
_SEMANTIC_EXCLUSIONS: dict[str, list[dict[str, str]]] = {
    "ExtractRequest": [
        {
            "method": "_validate_images_or_image_url",
            "check": "self.images and self.image_url is not None",
            "error": "Provide either 'images' or 'image_url', not both",
        },
    ],
}

# Proto3 zero values for non-optional Elixir struct fields.
EX_ZERO_VALUES: dict[str, str] = {
    "TYPE_STRING": '""',
    "TYPE_ENUM": '""',
    "TYPE_BYTES": '""',
    "TYPE_BOOL": "false",
    "TYPE_INT32": "0",
    "TYPE_INT64": "0",
    "TYPE_UINT32": "0",
    "TYPE_UINT64": "0",
    "TYPE_SINT32": "0",
    "TYPE_SINT64": "0",
    "TYPE_FIXED32": "0",
    "TYPE_FIXED64": "0",
    "TYPE_SFIXED32": "0",
    "TYPE_SFIXED64": "0",
    "TYPE_FLOAT": "0.0",
    "TYPE_DOUBLE": "0.0",
}

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------


def load_descriptor() -> dict:
    """Run buf build and return the parsed JSON FileDescriptorSet."""
    tmp_fd, tmp_path = tempfile.mkstemp(suffix=".json")
    os.close(tmp_fd)
    tmp = Path(tmp_path)
    try:
        result = subprocess.run(
            ["buf", "build", "--as-file-descriptor-set", "-o", f"{tmp}#format=json"],
            capture_output=True,
            text=True,
            cwd=PROTO_DIR,
        )
        if result.returncode != 0:
            print(
                f"ERROR: buf build failed:\n{result.stderr}\n"
                "Ensure buf ≥ v1.0 is installed (brew install bufbuild/buf/buf).",
                file=sys.stderr,
            )
            sys.exit(1)
        data: dict = json.loads(tmp.read_text())
        return data
    finally:
        tmp.unlink(missing_ok=True)


def _get_target_file(descriptor: dict, proto_file: str) -> dict:
    target = next((f for f in descriptor.get("file", []) if f["name"] == proto_file), None)
    if target is None:
        print(f"ERROR: '{proto_file}' not found in descriptor", file=sys.stderr)
        sys.exit(1)
    return target


def _collect_all_messages(messages: list[dict]) -> list[dict]:
    """Recursively collect all messages including nested types (nestedType).

    buf's JSON descriptor stores nested message definitions under the 'nestedType'
    key of their enclosing message, not in the flat top-level 'messageType' list.
    Flattening here ensures needs_datetime/needs_any detection and toposort both
    see nested types correctly.
    """
    result = []
    for msg in messages:
        result.append(msg)
        nested = msg.get("nestedType", [])
        if nested:
            result.extend(_collect_all_messages(nested))
    return result


def _toposort_messages(messages: list[dict]) -> list[dict]:
    """Sort messages so dependencies are defined before the types that reference them."""
    name_to_msg = {m["name"]: m for m in messages}
    deps: dict[str, set[str]] = {m["name"]: set() for m in messages}

    for msg in messages:
        for field in msg.get("field", []):
            if field.get("type") == "TYPE_MESSAGE":
                ref = field.get("typeName", "").rsplit(".", 1)[-1]
                if ref in name_to_msg and ref != msg["name"]:
                    deps[msg["name"]].add(ref)

    ordered: list[dict] = []
    ready = [n for n, d in deps.items() if not d]
    while ready:
        name = ready.pop(0)
        ordered.append(name_to_msg[name])
        for n, d in deps.items():
            d.discard(name)
            if not d and name_to_msg[n] not in ordered and n not in ready:
                ready.append(n)

    if len(ordered) != len(messages):
        print(
            "ERROR: cycle detected in message dependency graph — cannot generate output",
            file=sys.stderr,
        )
        sys.exit(1)
    return ordered


def _resolve_field(
    field: dict,
    local_messages: set[str],
    scalar_map: dict[str, str],
    wkt_map: dict[str, str],
    language: str = "python",
) -> tuple[str, bool, bool]:
    """Return (inner_type, is_optional, is_repeated).

    is_optional is True for proto3 optional fields AND for members of a real oneof
    (both are represented with oneofIndex in the descriptor).
    """
    proto_type = field.get("type", "")
    type_name = field.get("typeName", "")
    # Fields with oneofIndex cover two cases:
    #   1. proto3 optional (oneofIndex + proto3Optional=true) — truly nullable
    #   2. real oneof members (oneofIndex without proto3Optional) — mutually exclusive
    # Both are generated as nullable here. Real oneof mutual-exclusion constraints
    # are not enforced by the generated types — application code must validate.
    is_optional = "oneofIndex" in field
    is_repeated = field.get("label", "") == "LABEL_REPEATED"

    if proto_type in scalar_map:
        inner = scalar_map[proto_type]
    elif proto_type == "TYPE_ENUM":
        inner = "String" if language == "rust" else "str"
    elif proto_type == "TYPE_MESSAGE":
        if type_name in wkt_map:
            inner = wkt_map[type_name]
        else:
            class_name = type_name.rsplit(".", 1)[-1]
            if class_name not in local_messages:
                print(
                    f"ERROR: unknown message type '{type_name}' — "
                    "cross-file references are not yet supported",
                    file=sys.stderr,
                )
                sys.exit(1)
            inner = class_name
    else:
        print(f"ERROR: unhandled proto type '{proto_type}'", file=sys.stderr)
        sys.exit(1)

    return inner, is_optional, is_repeated


# ---------------------------------------------------------------------------
# Python generation
# ---------------------------------------------------------------------------


def _get_real_oneof_groups(msg: dict) -> dict[int, tuple[str, list[str]]]:
    """Return {oneof_index: (oneof_name, [field_names])} for real (non-synthetic) oneofs.

    Synthetic oneofs created by the proto3 `optional` keyword have names starting with '_'
    and proto3Optional=true on the field. They are excluded — only real `oneof` blocks remain.
    """
    oneof_decls = msg.get("oneofDecl", [])
    result: dict[int, tuple[str, list[str]]] = {}
    for i, decl in enumerate(oneof_decls):
        name = decl.get("name", "")
        if not name.startswith("_"):
            result[i] = (name, [])
    for field in msg.get("field", []):
        idx = field.get("oneofIndex")
        if idx is not None and idx in result:
            result[idx][1].append(field["name"])
    return result


def _render_py_oneof_validators(
    msg_name: str, oneof_groups: dict[int, tuple[str, list[str]]]
) -> list[str]:
    """Render @model_validator methods for real proto oneofs."""
    lines: list[str] = []
    for idx in sorted(oneof_groups):
        oneof_name, field_names = oneof_groups[idx]
        fields_tuple = "(" + ", ".join(f'"{f}"' for f in field_names) + ")"
        method_name = f"_validate_{oneof_name}_oneof"
        field_list = ", ".join(field_names)
        err_msg = f"Exactly one of {field_list} must be set (oneof '{oneof_name}')"
        lines += [
            "",
            '    @model_validator(mode="after")',
            f"    def {method_name}(self) -> {msg_name}:",
            f"        set_fields = [f for f in {fields_tuple} if getattr(self, f) is not None]",
            "        if len(set_fields) != 1:",
            f'            raise ValueError("{err_msg}")',
            "        return self",
        ]
    return lines


def _render_py_semantic_validators(msg_name: str) -> list[str]:
    """Render @model_validator methods for semantic mutual-exclusion rules."""
    exclusions = _SEMANTIC_EXCLUSIONS.get(msg_name, [])
    lines: list[str] = []
    for excl in exclusions:
        lines += [
            "",
            '    @model_validator(mode="after")',
            f'    def {excl["method"]}(self) -> {msg_name}:',
            f"        if {excl['check']}:",
            f'            raise ValueError("{excl["error"]}")',
            "        return self",
        ]
    return lines


def _render_py_field(field: dict, local_messages: set[str]) -> str:
    name = field["name"]
    proto_type = field.get("type", "")
    inner, is_optional, is_repeated = _resolve_field(
        field, local_messages, PY_SCALAR_TYPES, PY_WKT_TYPES, language="python"
    )
    if is_repeated:
        return f"    {name}: list[{inner}] = Field(default_factory=list)"
    elif is_optional:
        return f"    {name}: {inner} | None = None"
    else:
        # Emit a proto3 zero-value default so Pydantic doesn't raise ValidationError
        # when a sender omits a field (proto3 guarantees absent = zero value).
        zero = PY_ZERO_VALUES.get(proto_type)
        if zero is not None:
            return f"    {name}: {inner} = {zero}"
        # Message types and WKTs: no default (caller must supply them).
        return f"    {name}: {inner}"


def generate_python_module(descriptor: dict, proto_file: str) -> str:
    target_file = _get_target_file(descriptor, proto_file)
    messages = _toposort_messages(_collect_all_messages(target_file.get("messageType", [])))
    local_messages = {m["name"] for m in messages}

    needs_datetime = any(
        f.get("typeName") == ".google.protobuf.Timestamp"
        for m in messages
        for f in m.get("field", [])
    )
    needs_any = any(
        f.get("typeName") == ".google.protobuf.Struct" for m in messages for f in m.get("field", [])
    )
    needs_validator = any(
        _get_real_oneof_groups(m) or m["name"] in _SEMANTIC_EXCLUSIONS for m in messages
    )

    lines = [
        "# Generated by scripts/gen_python_proto.py — DO NOT EDIT MANUALLY.",
        f"# Source: {proto_file}",
        "# Regenerate: scripts/gen-python-proto.sh",
        "",
        "from __future__ import annotations",
        "",
    ]
    if needs_any:
        lines.append("from typing import Any")  # required by dict[str, Any] for Struct WKT fields
    if needs_datetime:
        lines.append("from datetime import datetime")

    # Always import Field — needed for repeated fields; harmless otherwise.
    if needs_validator:
        lines.append("from pydantic import BaseModel, Field, model_validator")
    else:
        lines.append("from pydantic import BaseModel, Field")
    lines += ["", ""]

    for i, msg in enumerate(messages):
        lines.append(f"class {msg['name']}(BaseModel):")
        fields = sorted(msg.get("field", []), key=lambda f: f.get("number", 0))
        if fields:
            for field in fields:
                lines.append(_render_py_field(field, local_messages))
        else:
            lines.append("    pass")
        # Emit model_validator methods for real proto oneofs and semantic exclusions.
        oneof_groups = _get_real_oneof_groups(msg)
        lines.extend(_render_py_oneof_validators(msg["name"], oneof_groups))
        lines.extend(_render_py_semantic_validators(msg["name"]))
        if i < len(messages) - 1:
            lines += ["", ""]

    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Rust generation
# ---------------------------------------------------------------------------


def _render_rs_field(field: dict, local_messages: set[str]) -> list[str]:
    name = field["name"]
    json_name = field.get("jsonName", name)
    inner, is_optional, is_repeated = _resolve_field(
        field, local_messages, RS_SCALAR_TYPES, RS_WKT_TYPES, language="rust"
    )

    if is_repeated:
        lines: list[str] = []
        if json_name != name:
            lines.append(
                f'    #[serde(rename = "{json_name}", skip_serializing_if = "Vec::is_empty")]'
            )
        else:
            lines.append('    #[serde(skip_serializing_if = "Vec::is_empty")]')
        lines.append(f"    pub {name}: Vec<{inner}>,")
        return lines
    elif is_optional:
        lines = []
        if json_name != name:
            lines.append(
                f'    #[serde(rename = "{json_name}", skip_serializing_if = "Option::is_none")]'
            )
        else:
            lines.append('    #[serde(skip_serializing_if = "Option::is_none")]')
        lines.append(f"    pub {name}: Option<{inner}>,")
        return lines
    else:
        lines = []
        if json_name != name:
            lines.append(f'    #[serde(rename = "{json_name}")]')
        lines.append(f"    pub {name}: {inner},")
        return lines


def generate_rust_module(descriptor: dict, proto_file: str) -> str:
    target_file = _get_target_file(descriptor, proto_file)
    messages = _toposort_messages(_collect_all_messages(target_file.get("messageType", [])))
    local_messages = {m["name"] for m in messages}

    lines = [
        "// Generated by scripts/gen_python_proto.py — DO NOT EDIT MANUALLY.",
        f"// Source: {proto_file}",
        "// Regenerate: scripts/gen-rust-proto.sh",
        "",
        "use serde::{Deserialize, Serialize};",
        "",
    ]

    for i, msg in enumerate(messages):
        # Default is required by #[serde(default)] — missing proto3 scalar fields
        # deserialise to zero values ("", 0, false) instead of failing.
        lines.append("#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]")
        lines.append("#[serde(default)]")
        fields = sorted(msg.get("field", []), key=lambda f: f.get("number", 0))
        if fields:
            lines.append(f"pub struct {msg['name']} {{")
            for field in fields:
                lines.extend(_render_rs_field(field, local_messages))
            lines.append("}")
        else:
            # cargo fmt requires inline braces for empty structs.
            lines.append(f"pub struct {msg['name']} {{}}")
        if i < len(messages) - 1:
            lines.append("")

    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Elixir generation
# ---------------------------------------------------------------------------


def _render_ex_struct_field(
    field: dict,
    local_messages: set[str],
    namespace: str,
) -> tuple[str, str]:
    """Return (defstruct_entry, typespec_type) for an Elixir struct field."""
    name = field["name"]
    proto_type = field.get("type", "")
    type_name = field.get("typeName", "")
    # Any field with oneofIndex is optional (proto3 optional or real oneof member).
    is_optional = "oneofIndex" in field
    is_repeated = field.get("label", "") == "LABEL_REPEATED"

    if proto_type in EX_SCALAR_TYPES:
        inner = EX_SCALAR_TYPES[proto_type]
    elif proto_type == "TYPE_ENUM":
        inner = "String.t()"
    elif proto_type == "TYPE_MESSAGE":
        if type_name in EX_WKT_TYPES:
            inner = EX_WKT_TYPES[type_name]
        else:
            class_name = type_name.rsplit(".", 1)[-1]
            if class_name not in local_messages:
                print(
                    f"ERROR: unknown message type '{type_name}' — "
                    "cross-file references are not yet supported",
                    file=sys.stderr,
                )
                sys.exit(1)
            inner = f"{namespace}.{class_name}.t()"
    else:
        print(f"ERROR: unhandled proto type '{proto_type}'", file=sys.stderr)
        sys.exit(1)

    if is_repeated:
        return f"{name}: []", f"[{inner}]"
    elif is_optional:
        return f"{name}: nil", f"{inner} | nil"
    else:
        # Non-optional proto3 scalar: emit the proto3 zero value.
        zero = EX_ZERO_VALUES.get(proto_type, "nil")
        if proto_type == "TYPE_MESSAGE":
            zero = "nil"  # embedded messages: nil is the only sensible default
        return f"{name}: {zero}", inner


def generate_elixir_module(descriptor: dict, proto_file: str) -> str:
    target_file = _get_target_file(descriptor, proto_file)
    messages = _toposort_messages(_collect_all_messages(target_file.get("messageType", [])))
    local_messages = {m["name"] for m in messages}

    stem = Path(proto_file).stem
    # PascalCase: handles multi-word stems ("my_service" → "MyService").
    namespace = f"Stacks.Proto.{''.join(w.capitalize() for w in stem.split('_'))}"

    lines = [
        "# Generated by scripts/gen_python_proto.py — DO NOT EDIT MANUALLY.",
        f"# Source: {proto_file}",
        "# Regenerate: scripts/gen-elixir-proto.sh",
        "",
    ]

    for i, msg in enumerate(messages):
        module_name = f"{namespace}.{msg['name']}"
        fields = sorted(msg.get("field", []), key=lambda f: f.get("number", 0))

        lines.append(f"defmodule {module_name} do")
        lines.append(
            f'  @moduledoc "Wire contract for {msg["name"]} — '
            f'generated from {proto_file}. Do not edit."'
        )
        # Note: @derive Jason.Encoder is intentionally omitted.
        # The explicit defimpl below provides custom nil-filtering; @derive
        # would generate a redundant default impl that competes with it.

        if fields:
            ds_entries: list[str] = []
            ts_entries: list[tuple[str, str]] = []
            for field in fields:
                ds, ts = _render_ex_struct_field(field, local_messages, namespace)
                ds_entries.append(ds)
                ts_entries.append((field["name"], ts))

            # mix format: `defstruct key: val,\n            key2: val2` (no brackets)
            # "  defstruct " = 12 chars → continuation lines use 12-space indent
            lines.append("")
            if len(ds_entries) == 1:
                lines.append(f"  defstruct {ds_entries[0]}")
            else:
                continuation = " " * 12
                lines.append(f"  defstruct {ds_entries[0]},")
                for entry in ds_entries[1:-1]:
                    lines.append(f"{continuation}{entry},")
                lines.append(f"{continuation}{ds_entries[-1]}")

            # mix format: @type fields at 10-space indent, closing `}` at 8-space indent
            lines.append("")
            lines.append("  @type t() :: %__MODULE__{")
            field_indent = " " * 10
            close_indent = " " * 8
            for j, (fname, ftype) in enumerate(ts_entries):
                comma = "," if j < len(ts_entries) - 1 else ""
                lines.append(f"{field_indent}{fname}: {ftype}{comma}")
            lines.append(f"{close_indent}}}")
        else:
            lines.append("")
            lines.append("  defstruct []")
            lines.append("")
            lines.append("  @type t() :: %__MODULE__{}")

        lines.append("end")
        lines.append("")
        # Custom Jason.Encoder that omits nil optional fields (proto3 JSON semantics).
        lines.append(f"defimpl Jason.Encoder, for: {module_name} do")
        lines.append("  def encode(struct, opts) do")
        lines.append("    struct")
        lines.append("    |> Map.from_struct()")
        lines.append("    |> Enum.reject(fn {_, v} -> is_nil(v) end)")
        lines.append("    |> Map.new()")
        lines.append("    |> Jason.Encode.map(opts)")
        lines.append("  end")
        lines.append("end")
        if i < len(messages) - 1:
            lines.append("")

    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

GENERATORS = {
    "python": generate_python_module,
    "rust": generate_rust_module,
    "elixir": generate_elixir_module,
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Verify generated files match proto; exit 1 if any drift detected.",
    )
    parser.add_argument(
        "--language",
        choices=["python", "rust", "elixir", "all"],
        default="all",
        help="Generate only the specified language targets (default: all).",
    )
    args = parser.parse_args()

    targets = (
        TARGETS
        if args.language == "all"
        else [t for t in TARGETS if t["language"] == args.language]
    )

    descriptor = load_descriptor()
    drift_detected = False

    for target in targets:
        proto_file: str = target["proto_file"]
        output: Path = target["output"]
        language: str = target["language"]
        generate = GENERATORS[language]

        generated = generate(descriptor, proto_file)

        if args.check:
            if not output.exists():
                print(
                    f"DRIFT: {output.relative_to(REPO_ROOT)} does not exist — "
                    f"run: scripts/gen-{language}-proto.sh",
                    file=sys.stderr,
                )
                drift_detected = True
            elif output.read_text() != generated:
                print(
                    f"DRIFT: {output.relative_to(REPO_ROOT)} is out of date — "
                    f"run: scripts/gen-{language}-proto.sh",
                    file=sys.stderr,
                )
                drift_detected = True
            else:
                print(f"OK: {output.relative_to(REPO_ROOT)}", file=sys.stderr)
        else:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(generated)
            print(f"Generated: {output.relative_to(REPO_ROOT)}")

    # Check or write package init files.
    if args.check:
        drift_detected = _check_package_inits(targets) or drift_detected
    else:
        _write_package_inits(targets)

    if drift_detected:
        sys.exit(1)


def _compute_mod_rs(targets: list[dict], existing: str) -> str:
    """Compute the expected mod.rs content for Rust targets."""
    rust_targets = [t for t in targets if t["language"] == "rust"]
    new_stems = {t["output"].stem for t in rust_targets}
    # Merge existing pub mod declarations so single-language runs preserve other modules.
    existing_stems: set[str] = set()
    for line in existing.splitlines():
        stripped = line.strip()
        if stripped.startswith("pub mod ") and stripped.endswith(";"):
            existing_stems.add(stripped[len("pub mod ") : -1])
    all_stems = sorted(existing_stems | new_stems)
    mod_content = "".join(f"pub mod {stem};\n" for stem in all_stems)
    # Preserve the existing #[cfg(test)] block if present.
    # Use split() to avoid fragile str.index() when multiple cfg(test) markers exist.
    if "#[cfg(test)]" in existing:
        parts = existing.split("#[cfg(test)]", 1)
        test_block = "#[cfg(test)]" + parts[1]
        return mod_content + "\n" + test_block
    return mod_content


def _check_package_inits(targets: list[dict]) -> bool:
    """Check that package/module init files match what would be generated. Returns True if drift."""
    drift = False
    # Python: __init__.py must exist alongside each generated .py file.
    for target in targets:
        if target["language"] == "python":
            init = target["output"].parent / "__init__.py"
            if not init.exists():
                print(
                    f"DRIFT: {init.relative_to(REPO_ROOT)} does not exist — "
                    "run: scripts/gen-python-proto.sh",
                    file=sys.stderr,
                )
                drift = True
            else:
                print(f"OK: {init.relative_to(REPO_ROOT)}", file=sys.stderr)

    # Rust: mod.rs must list all generated modules.
    rust_targets = [t for t in targets if t["language"] == "rust"]
    if rust_targets:
        rust_out_dir = rust_targets[0]["output"].parent
        mod_rs = rust_out_dir / "mod.rs"
        existing = mod_rs.read_text() if mod_rs.exists() else ""
        # In check mode pass empty string so stale stems (modules removed from TARGETS)
        # are detected as drift rather than silently preserved.
        expected = _compute_mod_rs(targets, "")
        if not mod_rs.exists():
            print(
                f"DRIFT: {mod_rs.relative_to(REPO_ROOT)} does not exist — "
                "run: scripts/gen-rust-proto.sh",
                file=sys.stderr,
            )
            drift = True
        elif existing != expected:
            print(
                f"DRIFT: {mod_rs.relative_to(REPO_ROOT)} is out of date — "
                "run: scripts/gen-rust-proto.sh",
                file=sys.stderr,
            )
            drift = True
        else:
            print(f"OK: {mod_rs.relative_to(REPO_ROOT)}", file=sys.stderr)
    return drift


def _write_package_inits(targets: list[dict]) -> None:
    """Write package/module init files for all generated targets."""
    # Python: __init__.py alongside each generated .py file.
    for target in targets:
        if target["language"] == "python":
            init = target["output"].parent / "__init__.py"
            if not init.exists():
                init.write_text("")

    # Rust: single mod.rs listing all generated modules.
    rust_targets = [t for t in targets if t["language"] == "rust"]
    if rust_targets:
        rust_out_dir = rust_targets[0]["output"].parent
        mod_rs = rust_out_dir / "mod.rs"
        existing = mod_rs.read_text() if mod_rs.exists() else ""
        mod_rs.write_text(_compute_mod_rs(targets, existing))


if __name__ == "__main__":
    main()
