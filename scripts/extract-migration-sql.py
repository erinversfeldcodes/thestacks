#!/usr/bin/env python3
"""Extract squawk-analysable SQL from an Ecto migration (219). squawk
historically saw only `execute("...")` strings, so DSL-expressed
hazards (e.g. a non-concurrent unique_index locking the table) were
invisible — the 210 blind spot. Single source of truth for
migration-file -> SQL-stream used by both security-squawk.sh and its
test wrapper: runs the migration with a stubbed connection that
records SQL instead of executing it, then emits DSL-derived DDL.
"""

import re
import sys


def _extract_execute_blocks(src: str) -> list[str]:
    blocks: list[str] = []
    blocks += [m.group(1) for m in re.finditer(r'execute\s*\(\s*"""(.*?)"""', src, re.DOTALL)]
    blocks += [m.group(1) for m in re.finditer(r'execute\s*\(\s*"([^"]+)"\s*\)', src)]
    out = []
    for b in blocks:
        if "#{" in b:  # Elixir interpolation — not analysable
            continue
        if re.search(r"DO\s*\$\$", b, re.IGNORECASE):  # anonymous procedure
            continue
        stmt = b.strip()
        if stmt:
            out.append(stmt)
    return out


def _balanced_args(src: str, open_paren_pos: int) -> str:
    """Return the text between a `(` at open_paren_pos-1 and its matching `)`."""
    depth = 1
    j = open_paren_pos
    n = len(src)
    while j < n and depth > 0:
        c = src[j]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        j += 1
    return src[open_paren_pos : j - 1]


def _parse_index_call(args: str) -> dict:
    """Pull table / prefix / columns / name / flags out of a create index arg list."""
    prefix = None
    m = re.search(r'prefix:\s*"([^"]+)"', args)
    if m:
        prefix = m.group(1)

    table = None
    m = re.search(r"table\(\s*:([a-z_][a-z0-9_]*)", args)
    if m:
        table = m.group(1)
    else:
        m = re.match(r"\s*:([a-z_][a-z0-9_]*)", args)
        if m:
            table = m.group(1)

    columns: list[str] = []
    m = re.search(r"\[(.*?)\]", args, re.DOTALL)
    if m:
        for item in m.group(1).split(","):
            item = item.strip()
            if not item:
                continue
            am = re.match(r":([a-z_][a-z0-9_]*)$", item)
            if am:
                columns.append(am.group(1))
                continue
            sm = re.match(r'"(.*)"$', item)
            if sm:
                columns.append(sm.group(1))

    name = None
    m = re.search(r"name:\s*:([a-z_][a-z0-9_]*)", args) or re.search(r'name:\s*"([^"]+)"', args)
    if m:
        name = m.group(1)

    concurrently = bool(re.search(r"concurrently:\s*true", args))
    return {
        "prefix": prefix,
        "table": table,
        "columns": columns,
        "name": name,
        "concurrently": concurrently,
    }


def _translate_create_table_dsl(src: str) -> list[str]:
    """Declare every table this migration creates, so squawk has the context.

    Emits a column-less `CREATE TABLE ...;` per `create table(...)` /
    `create_if_not_exists table(...)` DSL call. squawk tracks table names
    created earlier in the same source file and stops warning about operations
    on them — which is correct, because a table nothing can read yet cannot be
    locked out from under anyone. Columns are deliberately omitted: squawk does
    not resolve column references, and inventing them would risk tripping
    unrelated column-shape rules on statements the author never wrote.
    """
    out: list[str] = []
    seen: list[str] = []
    for m in re.finditer(r"\bcreate(?:_if_not_exists)?\s+table\s*\(", src):
        args = _balanced_args(src, m.end())
        info = _parse_index_call(args)
        table = info["table"]
        if not table:
            continue
        qualified = f"{info['prefix']}.{table}" if info["prefix"] else table
        if qualified in seen:
            continue
        seen.append(qualified)
        out.append(f"CREATE TABLE {qualified} ();")
    return out


def _translate_index_dsl(src: str) -> list[str]:
    """Synthesise CREATE INDEX SQL for each create (unique_)index DSL call."""
    out: list[str] = []
    for m in re.finditer(r"\bcreate(?:_if_not_exists)?\s+(unique_)?index\s*\(", src):
        unique = bool(m.group(1))
        args = _balanced_args(src, m.end())
        info = _parse_index_call(args)
        table = info["table"]
        if not table or not info["columns"]:
            continue
        qualified = f"{info['prefix']}.{table}" if info["prefix"] else table
        cols = ", ".join(info["columns"])
        name = info["name"] or f"{table}_idx"
        unique_kw = "UNIQUE " if unique else ""
        if info["concurrently"]:
            out.append(
                f"CREATE {unique_kw}INDEX CONCURRENTLY IF NOT EXISTS "
                f"{name} ON {qualified} ({cols});"
            )
        else:
            out.append(f"CREATE {unique_kw}INDEX {name} ON {qualified} ({cols});")
    return out


def extract(path: str) -> list[str]:
    with open(path) as f:
        src = f.read()
    subject: list[str] = []
    subject += _extract_execute_blocks(src)
    subject += _translate_index_dsl(src)
    statements = (_translate_create_table_dsl(src) + subject) if subject else []
    return [s if s.rstrip().endswith(";") else s + ";" for s in statements]


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <migration.exs>", file=sys.stderr)
        return 2
    for stmt in extract(sys.argv[1]):
        print(stmt)
    return 0


if __name__ == "__main__":
    sys.exit(main())
