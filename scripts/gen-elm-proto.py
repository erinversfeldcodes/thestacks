#!/usr/bin/env python3
"""Generate Elm JSON decoder/encoder modules from a buf JSON FileDescriptorSet.

Reads the JSON image from stdin (produced by `buf build -o /dev/stdout`).
Writes one .elm file per .proto file to the output directory.

No external dependencies — uses only Python 3 stdlib.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

SCALAR_TYPE_MAP: dict[str, tuple[str, str, str]] = {
    "TYPE_STRING": ("String", "D.string", "E.string"),
    "TYPE_BYTES": ("String", "D.string", "E.string"),
    "TYPE_INT32": ("Int", "D.int", "E.int"),
    "TYPE_INT64": ("Int", "D.int", "E.int"),
    "TYPE_UINT32": ("Int", "D.int", "E.int"),
    "TYPE_UINT64": ("Int", "D.int", "E.int"),
    "TYPE_SINT32": ("Int", "D.int", "E.int"),
    "TYPE_SINT64": ("Int", "D.int", "E.int"),
    "TYPE_FIXED32": ("Int", "D.int", "E.int"),
    "TYPE_FIXED64": ("Int", "D.int", "E.int"),
    "TYPE_SFIXED32": ("Int", "D.int", "E.int"),
    "TYPE_SFIXED64": ("Int", "D.int", "E.int"),
    "TYPE_FLOAT": ("Float", "D.float", "E.float"),
    "TYPE_DOUBLE": ("Float", "D.float", "E.float"),
    "TYPE_BOOL": ("Bool", "D.bool", "E.bool"),
}

WKT_TIMESTAMP = ".google.protobuf.Timestamp"
WKT_STRUCT = ".google.protobuf.Struct"


@dataclass
class EnumValue:
    name: str  # e.g. "VISIBILITY_TIER_PUBLIC"
    number: int


@dataclass
class EnumDef:
    name: str  # e.g. "VisibilityTier"
    values: list[EnumValue]
    fqn: str = ""  # e.g. ".stacks.common.v1.VisibilityTier"


@dataclass
class FieldDef:
    name: str  # proto field name (snake_case)
    json_name: str  # JSON wire name
    number: int
    label: str  # LABEL_OPTIONAL, LABEL_REPEATED
    type_str: str  # TYPE_STRING, TYPE_MESSAGE, TYPE_ENUM, etc.
    type_name: str  # fully qualified type ref for message/enum fields
    proto3_optional: bool  # explicit `optional` keyword in proto3


@dataclass
class MessageDef:
    name: str  # e.g. "Book"
    fields: list[FieldDef]
    fqn: str = ""  # e.g. ".stacks.common.v1.Book"


@dataclass
class FileDef:
    name: str  # e.g. "stacks/common/v1/book.proto"
    package: str  # e.g. "stacks.common.v1"
    enums: list[EnumDef]
    messages: list[MessageDef]
    is_import: bool


def _parse_enums_recursive(container: dict, package: str, parent_prefix: str = "") -> list[EnumDef]:
    """Parse enums from a descriptor, including nested enums (Finding #4)."""
    enums: list[EnumDef] = []
    for e in container.get("enumType", []):
        values = [EnumValue(name=v["name"], number=v.get("number", 0)) for v in e.get("value", [])]
        qualified_name = f"{parent_prefix}{e['name']}" if parent_prefix else e["name"]
        fqn = f".{package}.{qualified_name}" if package else f".{qualified_name}"
        enums.append(EnumDef(name=e["name"], values=values, fqn=fqn))
    return enums


def _parse_messages_recursive(
    container: dict, package: str, parent_prefix: str = "", *, key: str = "messageType"
) -> tuple[list[MessageDef], list[EnumDef]]:
    """Parse messages from a descriptor, including nested messages and enums.

    Args:
        container: The descriptor dict containing message definitions.
        package: The proto package name (e.g. "stacks.common.v1").
        parent_prefix: Dot-separated prefix for nested type qualified names.
        key: The dict key to read messages from — "messageType" for top-level
             containers, "nestedType" for messages nested inside other messages.
    """
    messages: list[MessageDef] = []
    nested_enums: list[EnumDef] = []
    for m in container.get(key, []):
        qualified_name = f"{parent_prefix}{m['name']}" if parent_prefix else m["name"]
        fields: list[FieldDef] = []
        for fld in m.get("field", []):
            fields.append(
                FieldDef(
                    name=fld["name"],
                    json_name=fld.get("jsonName", fld["name"]),
                    number=fld.get("number", 0),
                    label=fld.get("label", "LABEL_OPTIONAL"),
                    type_str=fld.get("type", "TYPE_STRING"),
                    type_name=fld.get("typeName", ""),
                    proto3_optional=fld.get("proto3Optional", False),
                )
            )
        fqn = f".{package}.{qualified_name}" if package else f".{qualified_name}"
        messages.append(MessageDef(name=m["name"], fields=fields, fqn=fqn))

        nested_enums.extend(_parse_enums_recursive(m, package, f"{qualified_name}."))
        sub_msgs, sub_enums = _parse_messages_recursive(
            m, package, f"{qualified_name}.", key="nestedType"
        )
        messages.extend(sub_msgs)
        nested_enums.extend(sub_enums)

    return messages, nested_enums


def parse_descriptor(data: dict) -> list[FileDef]:
    """Parse the buf JSON image into our data model."""
    files: list[FileDef] = []
    for f in data.get("file", []):
        is_import = f.get("bufExtension", {}).get("isImport", False)
        package = f.get("package", "")

        enums: list[EnumDef] = _parse_enums_recursive(f, package)

        messages, nested_enums = _parse_messages_recursive(f, package, key="messageType")
        enums.extend(nested_enums)

        files.append(
            FileDef(
                name=f["name"],
                package=package,
                enums=enums,
                messages=messages,
                is_import=is_import,
            )
        )
    return files


def screaming_snake_to_pascal(s: str) -> str:
    """VISIBILITY_TIER_PUBLIC -> VisibilityTierPublic"""
    return "".join(part.capitalize() for part in s.split("_"))


def enum_value_to_elm_ctor(enum_name: str, value_name: str) -> str:
    """Convert a proto enum value name to an Elm constructor name.

    Uses the proto enum type name (PascalCase) as the prefix, then appends
    the PascalCased suffix after stripping the SCREAMING_SNAKE prefix.

    Examples:
        ISBNFormat, ISBN_FORMAT_UNSPECIFIED -> ISBNFormatUnspecified
        ISBNFormat, ISBN_FORMAT_ISBN_10     -> ISBNFormatIsbn10
        VisibilityTier, VISIBILITY_TIER_PUBLIC -> VisibilityTierPublic
        HealthStatus, HEALTH_STATUS_HEALTHY -> HealthStatusHealthy
    """
    prefix = _pascal_to_screaming_snake(enum_name)

    if value_name.startswith(prefix + "_"):
        suffix = value_name[len(prefix) + 1 :]
    elif value_name == prefix:
        suffix = ""
    else:
        return screaming_snake_to_pascal(value_name)

    if not suffix:
        return enum_name

    suffix_pascal = screaming_snake_to_pascal(suffix)
    return enum_name + suffix_pascal


def _enum_value_lowercase_form(enum_name: str, value_name: str) -> str:
    """Derive the lowercase wire form from a proto enum value name (Finding #5).

    VISIBILITY_TIER_PUBLIC -> "public"
    HEALTH_STATUS_HEALTHY -> "healthy"
    EDITION_FORMAT_LARGE_PRINT -> "large_print"
    ISBN_FORMAT_ISBN_10 -> "isbn_10"
    """
    prefix = _pascal_to_screaming_snake(enum_name)
    suffix = value_name[len(prefix) + 1 :] if value_name.startswith(prefix + "_") else value_name
    return suffix.lower()


def _pascal_to_screaming_snake(name: str) -> str:
    """ISBNFormat -> ISBN_FORMAT, VisibilityTier -> VISIBILITY_TIER.

    Splits on transitions: lowercase->uppercase, uppercase->uppercase+lowercase.
    """
    result: list[str] = []
    current: list[str] = []
    for i, ch in enumerate(name):
        if (
            ch.isupper()
            and current
            and (
                (i > 0 and name[i - 1].islower())
                or (
                    i + 1 < len(name)
                    and name[i + 1].islower()
                    and current
                    and current[-1].isupper()
                )
            )
        ):
            result.append("".join(current))
            current = []
        current.append(ch)
    if current:
        result.append("".join(current))
    return "_".join(w.upper() for w in result)


ELM_RESERVED_WORDS = {
    "type",
    "let",
    "in",
    "case",
    "of",
    "if",
    "then",
    "else",
    "module",
    "import",
    "exposing",
    "as",
    "port",
    "where",
    "infix",
}


def snake_to_camel(s: str) -> str:
    """snake_case -> camelCase (for Elm record fields).

    Appends an underscore if the result is an Elm reserved keyword.
    """
    parts = s.split("_")
    result = parts[0] + "".join(p.capitalize() for p in parts[1:])
    if result in ELM_RESERVED_WORDS:
        return result + "_"
    return result


def proto_file_to_elm_module(proto_name: str) -> str:
    """stacks/common/v1/book.proto -> Stacks.Common.V1.Book"""
    without_ext = proto_name.replace(".proto", "")
    parts = without_ext.split("/")
    return ".".join(part_to_pascal(p) for p in parts)


def part_to_pascal(s: str) -> str:
    """Convert a path segment to PascalCase.

    v1 -> V1, book -> Book, common -> Common, event_bus -> EventBus
    """
    if re.match(r"^v\d+$", s):
        return s.upper()
    return screaming_snake_to_pascal(s.upper()) if "_" in s else s[0].upper() + s[1:]


def elm_module_to_path(module_name: str) -> str:
    """Stacks.Common.V1.Book -> Stacks/Common/V1/Book.elm"""
    return module_name.replace(".", "/") + ".elm"


class TypeResolver:
    """Resolves proto type references to Elm types."""

    def __init__(self, files: list[FileDef]):
        self.enum_map: dict[str, EnumDef] = {}
        self.message_map: dict[str, MessageDef] = {}
        self.enum_file_map: dict[str, FileDef] = {}
        self.message_file_map: dict[str, FileDef] = {}

        for f in files:
            for e in f.enums:
                self.enum_map[e.fqn] = e
                self.enum_file_map[e.fqn] = f
            for m in f.messages:
                self.message_map[m.fqn] = m
                self.message_file_map[m.fqn] = f

    def is_wkt_timestamp(self, type_name: str) -> bool:
        return type_name == WKT_TIMESTAMP

    def is_wkt_struct(self, type_name: str) -> bool:
        return type_name == WKT_STRUCT

    def is_enum(self, type_name: str) -> bool:
        return type_name in self.enum_map

    def is_message(self, type_name: str) -> bool:
        return type_name in self.message_map

    def elm_type_for_field(self, fld: FieldDef) -> str:
        """Return the Elm type string for a field."""
        inner = self._inner_type(fld)
        if fld.label == "LABEL_REPEATED":
            return f"List {inner}" if " " not in inner else f"List ({inner})"
        if fld.proto3_optional:
            return f"Maybe {inner}" if " " not in inner else f"Maybe ({inner})"
        return inner

    def decoder_for_field(self, fld: FieldDef) -> str:
        """Return the full decoder expression for a field (including D.field wrapper)."""
        inner_decoder = self._inner_decoder(fld)
        json_key = fld.json_name

        if fld.label == "LABEL_REPEATED":
            return f'D.oneOf [ D.field "{json_key}" (D.list {inner_decoder}), D.succeed [] ]'
        if fld.proto3_optional:
            return f'D.maybe (D.field "{json_key}" {inner_decoder})'
        if self._is_defaultable(fld):
            default = self._default_value(fld)
            return f'D.oneOf [ D.field "{json_key}" {inner_decoder}, D.succeed {default} ]'
        if (
            fld.type_str == "TYPE_MESSAGE"
            and not self.is_wkt_timestamp(fld.type_name)
            and not self.is_wkt_struct(fld.type_name)
        ):
            msg_def = self.message_map.get(fld.type_name)
            if msg_def:
                default_ref = _default_function_name(msg_def)
                return f'D.oneOf [ D.field "{json_key}" {inner_decoder}, D.succeed {default_ref} ]'
        return f'D.field "{json_key}" {inner_decoder}'

    def encoder_for_field(self, fld: FieldDef, accessor: str) -> str:
        """Return the encoder expression for a field value."""
        inner_encoder = self._inner_encoder(fld)

        if fld.label == "LABEL_REPEATED":
            return f"E.list {inner_encoder} {accessor}"
        if fld.proto3_optional:
            enc_inner = inner_encoder
            return f"Maybe.withDefault E.null (Maybe.map {enc_inner} {accessor})"
        return f"{inner_encoder} {accessor}"

    def _inner_type(self, fld: FieldDef) -> str:
        if fld.type_str == "TYPE_MAP":
            raise ValueError(f"map fields not yet supported (field: {fld.name})")
        if fld.type_str in SCALAR_TYPE_MAP:
            return SCALAR_TYPE_MAP[fld.type_str][0]
        if fld.type_str == "TYPE_ENUM":
            enum_def = self.enum_map.get(fld.type_name)
            if enum_def:
                return enum_def.name
            return "String"
        if fld.type_str == "TYPE_MESSAGE":
            if self.is_wkt_timestamp(fld.type_name):
                return "String"
            if self.is_wkt_struct(fld.type_name):
                return "E.Value"
            msg_def = self.message_map.get(fld.type_name)
            if msg_def:
                return msg_def.name
            return "D.Value"
        return "String"

    def _inner_decoder(self, fld: FieldDef) -> str:
        if fld.type_str == "TYPE_MAP":
            raise ValueError(f"map fields not yet supported (field: {fld.name})")
        if fld.type_str in SCALAR_TYPE_MAP:
            return SCALAR_TYPE_MAP[fld.type_str][1]
        if fld.type_str == "TYPE_ENUM":
            enum_def = self.enum_map.get(fld.type_name)
            if enum_def:
                return f"decode{enum_def.name}"
            return "D.string"
        if fld.type_str == "TYPE_MESSAGE":
            if self.is_wkt_timestamp(fld.type_name):
                return "D.string"
            if self.is_wkt_struct(fld.type_name):
                return "D.value"
            msg_def = self.message_map.get(fld.type_name)
            if msg_def:
                return f"decode{msg_def.name}"
            return "D.value"
        return "D.string"

    def _inner_encoder(self, fld: FieldDef) -> str:
        if fld.type_str == "TYPE_MAP":
            raise ValueError(f"map fields not yet supported (field: {fld.name})")
        if fld.type_str in SCALAR_TYPE_MAP:
            return SCALAR_TYPE_MAP[fld.type_str][2]
        if fld.type_str == "TYPE_ENUM":
            enum_def = self.enum_map.get(fld.type_name)
            if enum_def:
                return f"encode{enum_def.name}"
            return "E.string"
        if fld.type_str == "TYPE_MESSAGE":
            if self.is_wkt_timestamp(fld.type_name):
                return "E.string"
            if self.is_wkt_struct(fld.type_name):
                return "identity"
            msg_def = self.message_map.get(fld.type_name)
            if msg_def:
                return f"encode{msg_def.name}"
            return "identity"
        return "E.string"

    def _is_defaultable(self, fld: FieldDef) -> bool:
        """In proto3, non-optional scalar/enum fields have default values.

        Message-type fields are handled separately with default records (Finding #3).
        """
        if fld.proto3_optional:
            return False
        if fld.type_str == "TYPE_MESSAGE":
            if self.is_wkt_timestamp(fld.type_name):
                return True
            return bool(self.is_wkt_struct(fld.type_name))
        return True

    def _default_value(self, fld: FieldDef) -> str:
        if fld.type_str in SCALAR_TYPE_MAP:
            elm_type = SCALAR_TYPE_MAP[fld.type_str][0]
            if elm_type == "String":
                return '""'
            if elm_type == "Int":
                return "0"
            if elm_type == "Float":
                return "0.0"
            if elm_type == "Bool":
                return "False"
        if fld.type_str == "TYPE_ENUM":
            enum_def = self.enum_map.get(fld.type_name)
            if enum_def:
                unspec = self._enum_unspecified(enum_def)
                return enum_value_to_elm_ctor(enum_def.name, unspec.name)
            return '""'
        if fld.type_str == "TYPE_MESSAGE":
            if self.is_wkt_timestamp(fld.type_name):
                return '""'
            if self.is_wkt_struct(fld.type_name):
                return "(E.object [])"
        return '""'

    def _enum_unspecified(self, enum_def: EnumDef) -> EnumValue:
        """Return the UNSPECIFIED (zero) value for an enum."""
        for v in enum_def.values:
            if v.number == 0:
                return v
        return enum_def.values[0]

    def needs_maybe_import(self, messages: list[MessageDef]) -> bool:
        """Check if any field in the messages uses Maybe (proto3_optional)."""
        for msg in messages:
            for fld in msg.fields:
                if fld.proto3_optional:
                    return True
        return False

    def _collect_transitive_types(
        self, msg_def: MessageDef, visited: set[str] | None = None
    ) -> set[str]:
        """Collect all type references reachable from a message's default record.

        This includes enum and message types referenced by fields, and
        recursively the types referenced by embedded message defaults.
        """
        if visited is None:
            visited = set()
        result: set[str] = set()
        for fld in msg_def.fields:
            type_name = fld.type_name
            if not type_name or self.is_wkt_timestamp(type_name) or self.is_wkt_struct(type_name):
                continue
            result.add(type_name)
            if fld.type_str == "TYPE_MESSAGE" and type_name not in visited:
                visited.add(type_name)
                sub_msg = self.message_map.get(type_name)
                if sub_msg:
                    result.update(self._collect_transitive_types(sub_msg, visited))
        return result

    def compute_imports(self, file_def: FileDef) -> list[str]:
        """Compute required cross-module imports for a file (Finding #1).

        Scans all fields in all messages for TYPE_MESSAGE and TYPE_ENUM
        references to types defined in OTHER proto files, then returns
        the Elm import statements needed. Also collects transitive types
        needed by default records of imported message types.

        Known limitation: transitive default-record dependencies may pull in
        symbols that are not directly referenced in this module's generated
        code (e.g. BookshelfResponses imports Book symbols because
        PlacementDetail's default record transitively references defaultBook).
        A full usage-analysis pass over the generated Elm source would be
        needed to prune these, but elm-make tolerates unused imports so this
        is cosmetic only.
        """
        this_module = proto_file_to_elm_module(file_def.name)
        import_map: dict[str, set[str]] = {}

        all_type_refs: set[str] = set()
        for msg in file_def.messages:
            all_type_refs.update(self._collect_transitive_types(msg))

        for type_name in all_type_refs:
            source_file: FileDef | None = None
            expose_items: list[str] = []

            if type_name in self.enum_file_map:
                source_file = self.enum_file_map[type_name]
                enum_def = self.enum_map[type_name]
                expose_items = [
                    f"{enum_def.name}(..)",
                    f"decode{enum_def.name}",
                    f"encode{enum_def.name}",
                ]
            elif type_name in self.message_file_map:
                source_file = self.message_file_map[type_name]
                msg_def = self.message_map[type_name]
                expose_items = [
                    msg_def.name,
                    f"default{msg_def.name}",
                    f"decode{msg_def.name}",
                    f"encode{msg_def.name}",
                ]

            if source_file is not None:
                source_module = proto_file_to_elm_module(source_file.name)
                if source_module != this_module:
                    if source_module not in import_map:
                        import_map[source_module] = set()
                    import_map[source_module].update(expose_items)

        import_lines: list[str] = []
        for module_name in sorted(import_map.keys()):
            items = sorted(import_map[module_name])
            exposing_str = ", ".join(items)
            import_lines.append(f"import {module_name} exposing ({exposing_str})")
        return import_lines


def _default_function_name(msg_def: MessageDef) -> str:
    """Return the Elm function name for the default record of a message type."""
    return f"default{msg_def.name}"


def _build_default_record(msg_def: MessageDef, resolver: TypeResolver) -> str:
    """Build a default record expression for a message type (Finding #2 and #3).

    Returns the named default function reference (e.g. defaultBook) instead
    of an inline record literal. This keeps generated lines short and readable.
    """
    return _default_function_name(msg_def)


def _generate_default_function(msg_def: MessageDef, resolver: TypeResolver) -> list[str]:
    """Generate a top-level default<TypeName> function for a message.

    Example output:
        defaultBook : Book
        defaultBook =
            { id = ""
            , title = ""
            , author = defaultAuthor
            ...
            }
    """
    lines: list[str] = []
    fname = _default_function_name(msg_def)

    lines.append(f"{fname} : {msg_def.name}")
    lines.append(f"{fname} =")

    if not msg_def.fields:
        lines.append("    {}")
        return lines

    for i, fld in enumerate(msg_def.fields):
        elm_name = snake_to_camel(fld.name)
        zero = _elm_zero_value(fld, resolver)
        prefix = "    { " if i == 0 else "    , "
        lines.append(f"{prefix}{elm_name} = {zero}")
    lines.append("    }")

    return lines


def generate_elm_module(file_def: FileDef, resolver: TypeResolver) -> str:
    """Generate a complete Elm module for one .proto file."""
    module_name = proto_file_to_elm_module(file_def.name)
    proto_short = file_def.name.rsplit("/", 1)[-1]
    package_display = file_def.package.replace(".", " ")

    lines: list[str] = []

    exposing_items = _build_exposing_list(file_def)

    lines.append(f"module {module_name} exposing")
    for i, item in enumerate(exposing_items):
        prefix = "    ( " if i == 0 else "    , "
        lines.append(f"{prefix}{item}")
    lines.append("    )")
    lines.append("")

    lines.append(f"{{-| Generated Elm JSON decoders/encoders for {package_display} {proto_short}.")
    lines.append("")
    lines.append(
        "DO NOT EDIT MANUALLY. Regenerate via scripts/gen-elm-proto.sh"
        f" after modifying {proto_short}."
    )
    lines.append("")
    lines.append(
        "JSON on the wire -- these decoders consume the JSON representation"
        " of the Protobuf messages."
    )
    lines.append(
        "Field numbers are not present in JSON; json\\_name attributes from"
        " the .proto file determine keys."
    )

    has_timestamp = False
    has_struct = False
    for msg in file_def.messages:
        for fld in msg.fields:
            if resolver.is_wkt_timestamp(fld.type_name):
                has_timestamp = True
            if resolver.is_wkt_struct(fld.type_name):
                has_struct = True
    if has_struct or has_timestamp:
        lines.append("")
        if has_struct:
            lines.append(
                "google.protobuf.Struct maps to Json.Encode.Value (arbitrary JSON object)."
            )
        if has_timestamp:
            lines.append(
                "google.protobuf.Timestamp maps to a string in RFC3339 format"
                " (Protobuf JSON encoding)."
            )

    lines.append("")
    lines.append("-}")
    lines.append("")

    lines.append("import Json.Decode as D")
    lines.append("import Json.Encode as E")

    cross_imports = resolver.compute_imports(file_def)
    if cross_imports:
        for imp in cross_imports:
            lines.append(imp)

    if resolver.needs_maybe_import(file_def.messages):
        pass  # Maybe is in elm/core, auto-imported
    lines.append("")
    lines.append("")

    if file_def.enums:
        for enum_def in file_def.enums:
            lines.extend(_generate_enum(enum_def))
            lines.append("")
            lines.append("")

    if file_def.messages:
        for msg_def in file_def.messages:
            lines.extend(_generate_message(msg_def, resolver))
            lines.append("")
            lines.append("")

    while lines and lines[-1] == "":
        lines.pop()
    return "\n".join(lines) + "\n"


def _build_exposing_list(file_def: FileDef) -> list[str]:
    """Build the sorted exposing list."""
    items: list[str] = []

    for msg in file_def.messages:
        items.append(msg.name)

    for enum_def in file_def.enums:
        items.append(f"{enum_def.name}(..)")

    for msg in file_def.messages:
        items.append(f"default{msg.name}")

    for enum_def in file_def.enums:
        items.append(f"decode{enum_def.name}")
    for msg in file_def.messages:
        items.append(f"decode{msg.name}")

    for enum_def in file_def.enums:
        items.append(f"encode{enum_def.name}")
    for msg in file_def.messages:
        items.append(f"encode{msg.name}")

    items.sort()
    return items


def _generate_enum(enum_def: EnumDef) -> list[str]:
    """Generate Elm type, decoder, and encoder for an enum."""
    lines: list[str] = []

    constructors = [enum_value_to_elm_ctor(enum_def.name, v.name) for v in enum_def.values]
    lines.append(f"type {enum_def.name}")
    for i, ctor in enumerate(constructors):
        prefix = "    = " if i == 0 else "    | "
        lines.append(f"{prefix}{ctor}")
    lines.append("")
    lines.append("")

    unspecified_ctor = constructors[0] if constructors else "Unknown"
    lines.append(f"decode{enum_def.name} : D.Decoder {enum_def.name}")
    lines.append(f"decode{enum_def.name} =")
    lines.append("    D.string")
    lines.append("        |> D.andThen")
    lines.append("            (\\s ->")
    lines.append("                case s of")

    for v in enum_def.values:
        if v.number == 0:
            continue
        ctor = enum_value_to_elm_ctor(enum_def.name, v.name)
        lowercase_form = _enum_value_lowercase_form(enum_def.name, v.name)
        lines.append(f'                    "{v.name}" ->')
        lines.append(f"                        D.succeed {ctor}")
        lines.append("")
        lines.append(f'                    "{lowercase_form}" ->')
        lines.append(f"                        D.succeed {ctor}")
        lines.append("")

    lines.append("                    _ ->")
    lines.append(f"                        D.succeed {unspecified_ctor}")
    lines.append("            )")
    lines.append("")
    lines.append("")

    param = enum_def.name[0].lower()
    lines.append(f"encode{enum_def.name} : {enum_def.name} -> E.Value")
    lines.append(f"encode{enum_def.name} {param} =")
    lines.append(f"    case {param} of")
    for v in enum_def.values:
        ctor = enum_value_to_elm_ctor(enum_def.name, v.name)
        lowercase_form = _enum_value_lowercase_form(enum_def.name, v.name)
        lines.append(f"        {ctor} ->")
        lines.append(f'            E.string "{lowercase_form}"')
        lines.append("")

    if lines and lines[-1] == "":
        lines.pop()

    return lines


def _generate_message(msg_def: MessageDef, resolver: TypeResolver) -> list[str]:
    """Generate Elm type alias, default function, decoder, and encoder for a message."""
    lines: list[str] = []
    fields = msg_def.fields

    if not fields:
        lines.append(f"type alias {msg_def.name} =")
        lines.append("    {}")
        lines.append("")
        lines.append("")
        fname = _default_function_name(msg_def)
        lines.append(f"{fname} : {msg_def.name}")
        lines.append(f"{fname} =")
        lines.append("    {}")
        lines.append("")
        lines.append("")
        lines.append(f"decode{msg_def.name} : D.Decoder {msg_def.name}")
        lines.append(f"decode{msg_def.name} =")
        lines.append("    D.succeed {}")
        lines.append("")
        lines.append("")
        lines.append(f"encode{msg_def.name} : {msg_def.name} -> E.Value")
        lines.append(f"encode{msg_def.name} _ =")
        lines.append("    E.object []")
        return lines

    lines.append(f"type alias {msg_def.name} =")
    for i, fld in enumerate(fields):
        elm_field_name = snake_to_camel(fld.name)
        elm_type = resolver.elm_type_for_field(fld)
        prefix = "    { " if i == 0 else "    , "
        lines.append(f"{prefix}{elm_field_name} : {elm_type}")
    lines.append("    }")
    lines.append("")
    lines.append("")

    lines.extend(_generate_default_function(msg_def, resolver))
    lines.append("")
    lines.append("")

    lines.append(f"decode{msg_def.name} : D.Decoder {msg_def.name}")
    lines.append(f"decode{msg_def.name} =")
    lines.extend(_generate_decoder_body(msg_def, resolver))
    lines.append("")
    lines.append("")

    lines.extend(_generate_encoder(msg_def, resolver))

    return lines


def _generate_decoder_body(msg_def: MessageDef, resolver: TypeResolver) -> list[str]:
    """Generate the decoder body using mapN + andThen pattern."""
    lines: list[str] = []
    fields = msg_def.fields
    n = len(fields)

    if n == 0:
        lines.append("    D.succeed {}")
        return lines

    if n <= 8:
        map_fn = f"D.map{n}" if n > 1 else "D.map"
        if n == 1:
            elm_field = snake_to_camel(fields[0].name)
            lines.append(f"    {map_fn} (\\{elm_field} -> {{ {elm_field} = {elm_field} }})")
        else:
            lines.append(f"    {map_fn} {msg_def.name}")

        for fld in fields:
            decoder_expr = resolver.decoder_for_field(fld)
            lines.append(f"        ({decoder_expr})")
        return lines

    first_8 = fields[:8]
    rest = fields[8:]

    all_field_names = [snake_to_camel(f.name) for f in fields]
    first_8_names = all_field_names[:8]

    lines.append(f"    D.map8 (\\{' '.join(first_8_names)} ->")
    record_fields = []
    for i, fld in enumerate(fields):
        elm_name = snake_to_camel(fld.name)
        if i < 8:
            record_fields.append(f"{elm_name} = {elm_name}")
        else:
            record_fields.append(f"{elm_name} = {_elm_zero_value(fld, resolver)}")

    lines.append("            { " + record_fields[0])
    for rf in record_fields[1:]:
        lines.append(f"            , {rf}")
    lines.append("            }")
    lines.append("        )")

    for fld in first_8:
        decoder_expr = resolver.decoder_for_field(fld)
        lines.append(f"        ({decoder_expr})")

    for fld in rest:
        elm_name = snake_to_camel(fld.name)
        decoder_expr = resolver.decoder_for_field(fld)
        lines.append("        |> D.andThen")
        lines.append("            (\\partial ->")
        lines.append(
            f"                D.map (\\{elm_name} -> {{ partial | {elm_name} = {elm_name} }})"
        )
        lines.append(f"                    ({decoder_expr})")
        lines.append("            )")

    return lines


def _elm_zero_value(fld: FieldDef, resolver: TypeResolver) -> str:
    """Return the Elm zero/default value for a field (used in andThen partial records)."""
    if fld.label == "LABEL_REPEATED":
        return "[]"
    if fld.proto3_optional:
        return "Nothing"
    if fld.type_str in SCALAR_TYPE_MAP:
        elm_type = SCALAR_TYPE_MAP[fld.type_str][0]
        if elm_type == "String":
            return '""'
        if elm_type == "Int":
            return "0"
        if elm_type == "Float":
            return "0.0"
        if elm_type == "Bool":
            return "False"
    if fld.type_str == "TYPE_ENUM":
        enum_def = resolver.enum_map.get(fld.type_name)
        if enum_def:
            unspec = resolver._enum_unspecified(enum_def)
            return enum_value_to_elm_ctor(enum_def.name, unspec.name)
    if fld.type_str == "TYPE_MESSAGE":
        if resolver.is_wkt_timestamp(fld.type_name):
            return '""'
        if resolver.is_wkt_struct(fld.type_name):
            return "(E.object [])"
        msg_def = resolver.message_map.get(fld.type_name)
        if msg_def:
            return _default_function_name(msg_def)
    return '""'


def _generate_encoder(msg_def: MessageDef, resolver: TypeResolver) -> list[str]:
    """Generate the encoder function for a message."""
    lines: list[str] = []
    fields = msg_def.fields

    param = msg_def.name.lower() if len(msg_def.name) <= 4 else _abbreviate(msg_def.name)

    lines.append(f"encode{msg_def.name} : {msg_def.name} -> E.Value")
    lines.append(f"encode{msg_def.name} {param} =")
    lines.append("    E.object")

    for i, fld in enumerate(fields):
        elm_name = snake_to_camel(fld.name)
        accessor = f"{param}.{elm_name}"
        encoder_expr = resolver.encoder_for_field(fld, accessor)

        if (
            fld.type_str == "TYPE_MESSAGE"
            and resolver.is_wkt_struct(fld.type_name)
            and not fld.proto3_optional
            and fld.label != "LABEL_REPEATED"
        ):
            encoder_expr = accessor

        prefix = "        [ " if i == 0 else "        , "
        lines.append(f'{prefix}( "{fld.json_name}", {encoder_expr} )')

    lines.append("        ]")

    return lines


def _abbreviate(name: str) -> str:
    """Create a short abbreviation for an Elm type name.

    EventEnvelope -> env, SourceHealthCheck -> check, Book -> book
    """
    words = re.findall(r"[A-Z][a-z]*", name)
    if not words:
        return name.lower()
    if len(words) == 1:
        return words[0].lower()
    last = words[-1].lower()
    if last in (
        "type",
        "let",
        "in",
        "case",
        "of",
        "if",
        "then",
        "else",
        "module",
        "import",
        "exposing",
        "as",
        "port",
    ):
        return words[-2].lower() + last.capitalize()
    return last


def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="Generate Elm decoders/encoders from buf JSON image"
    )
    parser.add_argument(
        "--output-dir",
        "-o",
        default="proto/gen/elm",
        help="Output directory for generated .elm files",
    )
    args = parser.parse_args()

    data = json.load(sys.stdin)
    files = parse_descriptor(data)
    resolver = TypeResolver(files)

    output_dir = Path(args.output_dir)

    generated: list[str] = []
    for file_def in files:
        if file_def.is_import:
            continue
        if not file_def.enums and not file_def.messages:
            continue

        module_name = proto_file_to_elm_module(file_def.name)
        rel_path = elm_module_to_path(module_name)
        out_path = output_dir / rel_path

        elm_code = generate_elm_module(file_def, resolver)

        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(elm_code)
        generated.append(str(out_path))
        print(f"  Generated: {rel_path}", file=sys.stderr)

    print(f"  {len(generated)} file(s) generated.", file=sys.stderr)


if __name__ == "__main__":
    main()
