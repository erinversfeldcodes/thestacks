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

# Both `execute` forms in ONE alternation, so `finditer` yields them in source
# order. They used to be scanned in two passes — every heredoc block first, then
# every single-line one — which silently reordered the SQL stream handed to
# squawk. That is not cosmetic: squawk's analysis is order-sensitive (a `SET
# lock_timeout` only covers statements AFTER it; a constraint added `NOT VALID`
# is only safe if the validation follows), so an out-of-order stream can both
# miss a real hazard and invent one that the migration does not contain. The
# heredoc branch is listed first because `"""` must win over `"`.
_EXECUTE_RE = re.compile(
    r'execute\s*\(\s*(?:"""(?P<heredoc>.*?)"""|"(?P<single>[^"]+)"\s*\))',
    re.DOTALL,
)


# ⛔ WHAT GETS DISCARDED HAS TO BE COUNTED, because partial extraction is worse
# than none.
#
# When a file yields NOTHING, `security-squawk.sh` prints
# "(no raw SQL — skipping)" and a reader can see it was not analysed. When a
# file yields SOME statements, squawk analyses those, finds nothing wrong, and
# the file is reported as inspected — so the summary's coverage count is a
# number of files looked at rather than of SQL examined.
#
# Measured on this repository: `20261019120000_grant_the_app_role_its_own_job_queue`
# yields exactly three statements — two `SET LOCAL` from `up/0` and one from
# `down/0` — while five `DO $$` blocks carrying twelve GRANT/REVOKE statements,
# an `ALTER DEFAULT PRIVILEGES` pair and two far-end assertions are discarded.
# squawk then reports "Found 0 issues in 1 file" with exit 0. The only SQL it
# saw was the timeout declarations, which are the one thing that cannot itself
# be unsafe. `20261016150000` has the identical shape.
UNANALYSABLE_MARKER = "-- UNANALYSABLE"


def _unmatched_execute_count(src: str) -> int:
    """`execute(` calls the regex never matched at all.

    ⚠️ The third blindness, and the only one that leaves no trace: a migration
    that builds its SQL in a helper — `execute(grants_up(), grants_down())` —
    matches neither alternation, so it is not "discarded" but never seen. Both
    other cases at least pass through the loop below.
    """
    return len(re.findall(r"execute\s*\(", src)) - len(_EXECUTE_RE.findall(src))


def _execute_statements(src: str) -> tuple[list[tuple[int, str]], list[str]]:
    """Analysable `execute(...)` strings with offsets, plus why anything was dropped."""
    out: list[tuple[int, str]] = []
    dropped: list[str] = []
    for m in _EXECUTE_RE.finditer(src):
        body = m.group("heredoc") if m.group("heredoc") is not None else m.group("single")
        if "#{" in body:  # Elixir interpolation — not analysable
            dropped.append("Elixir interpolation")
            continue
        if re.search(r"DO\s*\$\$", body, re.IGNORECASE):  # anonymous procedure
            dropped.append("DO $$ block")
            continue
        stmt = body.strip()
        if stmt:
            out.append((m.start(), stmt))

    unmatched = _unmatched_execute_count(src)
    if unmatched > 0:
        dropped.extend(["execute() with a non-literal argument"] * unmatched)

    return out, dropped


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


def _translate_index_dsl(src: str) -> list[tuple[int, str]]:
    """Synthesise CREATE INDEX SQL for each create (unique_)index DSL call.

    Each statement is paired with its source offset so it can be interleaved
    with the `execute(...)` strings in the order the migration runs them.
    """
    out: list[tuple[int, str]] = []
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
                (
                    m.start(),
                    f"CREATE {unique_kw}INDEX CONCURRENTLY IF NOT EXISTS "
                    f"{name} ON {qualified} ({cols});",
                )
            )
        else:
            out.append((m.start(), f"CREATE {unique_kw}INDEX {name} ON {qualified} ({cols});"))
    return out


def _strip_def_down(text: str) -> str:
    """Drop `def down`, so only the forward migration reaches squawk.

    ⚠️ `lint-migrations.sh` has always done this and this file did not, so the
    stream carried `up` and `down` statements interleaved. That contradicts the
    header above: the whole reason both `execute` forms share one alternation is
    that squawk's analysis is ORDER-SENSITIVE, and a rollback's statements
    appearing mid-stream is exactly the out-of-order hazard it warns about — a
    `SET lock_timeout` from `down/0` can appear to cover an `up/0` statement it
    will never run before.
    """
    m = re.search(r"^([ \t]*)def down(?:\([^)]*\))?\s+do\s*$", text, re.MULTILINE)
    if not m:
        return text
    indent = m.group(1)
    close = re.compile(r"^" + re.escape(indent) + r"end[ \t]*$", re.MULTILINE).search(text, m.end())
    if not close:
        return text
    return text[: m.start()] + text[close.end() :]


def extract(path: str) -> list[str]:
    with open(path) as f:
        src = f.read()
    src = _strip_def_down(src)
    # Sorted by source offset, so the stream squawk reads is the order the
    # migration executes. The CREATE TABLE stubs are the one deliberate
    # exception: they are context declarations rather than statements under
    # analysis, and must precede anything that references the table.
    positioned_execs, dropped = _execute_statements(src)
    positioned = sorted(positioned_execs + _translate_index_dsl(src))
    subject = [stmt for _, stmt in positioned]
    statements = (_translate_create_table_dsl(src) + subject) if subject else []
    out = [s if s.rstrip().endswith(";") else s + ";" for s in statements]

    # ⛔ Declared in the stream itself, as a SQL comment. squawk ignores
    # comments, so this changes nothing it analyses — but it makes the gap
    # VISIBLE to the caller, which is the whole point. Without it a partially
    # extracted migration is indistinguishable from a fully extracted one.
    if dropped:
        tally = ", ".join(f"{dropped.count(r)}x {r}" for r in sorted(set(dropped)))
        out.insert(
            0, f"{UNANALYSABLE_MARKER}: {len(dropped)} statement(s) not extracted ({tally});"
        )

    return out


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <migration.exs>", file=sys.stderr)
        return 2
    for stmt in extract(sys.argv[1]):
        print(stmt)
    return 0


if __name__ == "__main__":
    sys.exit(main())
