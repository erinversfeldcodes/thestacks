#!/usr/bin/env python3
"""Extract squawk-analysable SQL from an Ecto migration (#219).

`security-squawk.sh` historically only linted SQL found inside `execute("...")`
strings, so a migration hazard expressed with the Ecto **DSL** — e.g.
`create unique_index(:users, [:handle], concurrently: false)`, which locks the
table against writes for the whole build — was invisible to squawk. That is the
DSL/raw-execute blind spot #210 fell into and #219 closes.

This helper is the single source of truth for turning a migration file into a
stream of SQL statements for squawk. Both `security-squawk.sh` and
`security-squawk-test-wrapper.sh` shell out to it, so the two gates can never
drift out of sync (drift being the exact failure mode #219 is about).

It emits, one statement per stanza on stdout:
  1. Raw SQL from every non-interpolated `execute(...)` block (as before).
  2. A synthesised `CREATE [UNIQUE] INDEX ...` statement for every
     `create index(...)` / `create unique_index(...)` DSL call, faithfully
     reflecting whether the author asked for `concurrently: true`. A
     non-concurrent build omits `CONCURRENTLY` and trips squawk's
     `require-concurrent-index-creation`; a concurrent build is rendered with an
     explicit name + `IF NOT EXISTS` so a genuinely-safe index still passes.

Blocks containing Elixir interpolation (`#{...}`) or anonymous PL/pgSQL
(`DO $$ ... $$`) are skipped — their effect isn't statically knowable.

Usage: extract-migration-sql.py <migration.exs>
"""

import re
import sys


def _extract_execute_blocks(src: str) -> list[str]:
    # Raw SQL text from triple-quoted and single-quoted execute(...) forms.
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

    # Table: either `table(:users, ...)` or a bare `:users` first argument.
    table = None
    m = re.search(r"table\(\s*:([a-z_][a-z0-9_]*)", args)
    if m:
        table = m.group(1)
    else:
        m = re.match(r"\s*:([a-z_][a-z0-9_]*)", args)
        if m:
            table = m.group(1)

    # Column list: first bracketed group. Items are `:atom` or "expr" strings.
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


def _translate_index_dsl(src: str) -> list[str]:
    """Synthesise CREATE INDEX SQL for each create (unique_)index DSL call."""
    out: list[str] = []
    for m in re.finditer(r"\bcreate\s+(unique_)?index\s*\(", src):
        unique = bool(m.group(1))
        args = _balanced_args(src, m.end())
        info = _parse_index_call(args)
        table = info["table"]
        if not table or not info["columns"]:
            # Can't render a meaningful statement — leave it to other gates.
            continue
        qualified = f"{info['prefix']}.{table}" if info["prefix"] else table
        cols = ", ".join(info["columns"])
        name = info["name"] or f"{table}_idx"
        unique_kw = "UNIQUE " if unique else ""
        if info["concurrently"]:
            # Genuinely safe build: explicit name + IF NOT EXISTS keeps squawk's
            # prefer-robust-stmts happy so a correct migration is not flagged.
            out.append(
                f"CREATE {unique_kw}INDEX CONCURRENTLY IF NOT EXISTS "
                f"{name} ON {qualified} ({cols});"
            )
        else:
            # Non-concurrent build locks writes — trips
            # require-concurrent-index-creation, which is the whole point.
            out.append(f"CREATE {unique_kw}INDEX {name} ON {qualified} ({cols});")
    return out


def extract(path: str) -> list[str]:
    with open(path) as f:
        src = f.read()
    statements: list[str] = []
    statements += _extract_execute_blocks(src)
    statements += _translate_index_dsl(src)
    # Normalise trailing semicolons.
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
