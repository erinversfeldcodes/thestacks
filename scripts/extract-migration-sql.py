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
  1. A bare `CREATE TABLE <name> ();` for every table the migration itself
     creates via `create table(...)` / `create_if_not_exists table(...)`.
     No columns are rendered — squawk only needs to know the table is *new in
     this migration*, and knowing that suppresses a whole class of false
     positives (#337). An index built non-concurrently on a table that does not
     exist yet blocks nothing, so `require-concurrent-index-creation` must not
     fire there; likewise `adding-not-nullable-field` on a brand-new table.
     Without this stanza squawk saw a naked `CREATE INDEX` with no context and
     flagged 32 historically-correct table-creation migrations, which is how a
     gate gets switched off.
  2. Raw SQL from every non-interpolated `execute(...)` block (as before).
  3. A synthesised `CREATE [UNIQUE] INDEX ...` statement for every
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
    # `create_if_not_exists` must be matched as well as `create`. It was not,
    # which silently re-opened the whole #219 DSL blind spot for anyone who
    # reached for the idempotent form: `create_if_not_exists index(...,
    # concurrently: false)` was invisible to squawk. Found while auditing #337's
    # own evidence — 20260730200500 builds two indexes this way and the gate
    # extracted zero statements from it.
    for m in re.finditer(r"\bcreate(?:_if_not_exists)?\s+(unique_)?index\s*\(", src):
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
    subject: list[str] = []
    subject += _extract_execute_blocks(src)
    subject += _translate_index_dsl(src)
    # The CREATE TABLE stanzas are context, not subject matter: they exist only
    # so squawk can tell "new table" from "live table" while judging the
    # statements above. On their own they assert nothing, so a migration that
    # *only* creates tables still reports as having no analysable SQL rather
    # than as a vacuous green.
    statements = (_translate_create_table_dsl(src) + subject) if subject else []
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
