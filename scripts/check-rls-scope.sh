#!/usr/bin/env bash
# scripts/check-rls-scope.sh — every query against a row-level-secured table
# must establish a scope, and every worker's declared scope must be true.
#
# ⛔ WHY THIS GATE EXISTS AT ALL, AND WHY IT CANNOT BE A TEST. Four `op` tables
# carry row-level security, and their policies refuse a query with no request
# scope set. But the test environment connects as `postgres`, which is
# `rolsuper = true`, and **superusers bypass row-level security entirely** — so
# an unscoped query passes every one of the 4000+ tests and fails only on a
# deployed stack, where the application connects as the least-privilege role.
#
# A green suite is therefore not evidence about scoping, and a reviewer reading
# a diff is the only other thing standing between an unscoped query and
# production. This gate is the instrument that can actually go red.
#
# It checks two things:
#
#   1. Every module that references one of the four secured schemas AND runs a
#      Repo call establishes a scope somewhere — `Stacks.Scope.with_user/2`,
#      `set!/1`, `multi_step/2`, or a `SECURITY DEFINER` function written for a
#      question per-user scoping cannot answer.
#
#   2. Every worker declaring `scope: :system` touches NONE of those schemas.
#      ⚠️ That claim is checked rather than trusted: `:system` is the easy
#      answer when somebody does not want to think about which user a job acts
#      for, and it is the answer that silently breaks on a deployed stack.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

LIB="apps/core/lib/stacks"
SCHEMAS='Bookshelf|Placement|UserBlock|VisibilityGrant'
SCOPE_MARKERS='Scope\.with_user|Scope\.set!|Scope\.multi_step|op\.blocked_pair|op\.wishlist_user_ids|op\.placement_owners_for_edition'
REPO_CALLS='Repo\.(all|one|get|get!|get_by|aggregate|exists\?|insert|insert!|update|update!|delete|delete_all|update_all|insert_all|query!|query)'

# ⚠️ An allowlist as a `case`, not an associative array — ⛔ `declare -A` does
# not exist in bash 3.2, which is the system bash here, and the failure mode is
# the one this gate exists to prevent: the script errored on the declaration and
# still exited 0, reporting a clean pass having checked nothing.
#
# Each entry carries its reason. A module here is one whose reference to a
# secured schema is not a query against it — an alias used only in a typespec,
# a mention in prose, or a module that hands the work to a context that scopes
# for itself. Reasons are required, because an allowlist without them becomes a
# place to put whatever is inconvenient.
allow_reason() {
    case "$1" in
        "events/registry.ex")
            echo "names schemas in subscription metadata; runs no query of its own" ;;
        "visibility.ex")
            echo "asks op.blocked_pair and delegates every row read to Shelving/Social, which scope" ;;
        "admin/data.ex")
            echo "operator surface reached only through the admin pipeline, which scopes per request" ;;
        "feeds/handlers/placement_handler.ex")
            echo "enqueues RegenerateFeedJob; the job scopes at its context boundary" ;;
        "insights.ex")
            echo "reads marts, not op; the schema names appear in doc prose" ;;
        "costs.ex")
            echo "reads op.platform_costs; the schema names appear in doc prose" ;;
        "books.ex")
            echo "book-side reads; placement access goes through Shelving, which scopes" ;;
        "marketplace/marketplace.ex")
            echo "listing reads are governed by the active-listing policy, not a per-user scope" ;;
        *) echo "" ;;
    esac
}

fail=0
checked=0
echo "==> Checking every module that queries a row-level-secured table"

while IFS= read -r file; do
    rel="${file#"$LIB"/}"

    grep -qE "$SCHEMAS" "$file" || continue
    grep -qE "$REPO_CALLS" "$file" || continue

    checked=$(( checked + 1 ))

    reason="$(allow_reason "$rel")"
    if [[ -n "$reason" ]]; then
        echo "    ALLOWED ${rel} — ${reason}"
        continue
    fi

    if grep -qE "$SCOPE_MARKERS" "$file"; then
        echo "    ok      ${rel}"
    else
        echo "    MISSING ${rel} — queries a row-level-secured table and establishes no scope" >&2
        fail=1
    fi
done < <(find "$LIB" -name '*.ex' -type f ! -path '*/gen/*' | sort)

# ⛔ Anti-vacuity. If the discovery above matched nothing — a moved directory, a
# renamed schema module — every assertion would pass over an empty set and this
# gate would report a clean bill of health having looked at nothing.
if (( checked < 8 )); then
    echo "FAIL: only ${checked} module(s) were examined, which is too few to be this codebase." >&2
    echo "      The discovery pattern has stopped matching; fix it before trusting a pass." >&2
    exit 1
fi
echo "    (${checked} module(s) examined)"

echo "==> Checking every worker's declared scope is true"
workers=0
for file in apps/core/lib/stacks/workers/*.ex; do
    grep -q "use Stacks.Worker" "$file" || continue
    workers=$(( workers + 1 ))
    name="$(basename "$file")"

    if grep -q "scope: :system" "$file"; then
        # ⚠️ Comments do not count. A `:system` worker may legitimately MENTION
        # these tables in prose explaining what it does not touch — one of them
        # does — so the claim is tested against code with comments stripped.
        if sed 's/#.*//' "$file" | grep -qE "$SCHEMAS"; then
            echo "    FALSE CLAIM ${name} — declares scope: :system but references a secured schema" >&2
            fail=1
        fi
    elif ! grep -q "scope: :user" "$file"; then
        echo "    UNDECLARED ${name} — no scope declaration" >&2
        fail=1
    fi
done

if (( workers < 30 )); then
    echo "FAIL: only ${workers} worker(s) found; the glob has stopped matching." >&2
    exit 1
fi
echo "    (${workers} worker(s) checked)"

if (( fail )); then
    echo "FAIL: a query against a row-level-secured table has no scope." >&2
    echo "      Establish one with Stacks.Scope.with_user/2 (or set!/1 inside a transaction" >&2
    echo "      the caller owns), or allowlist the module here WITH the reason." >&2
    exit 1
fi

echo "OK: every module querying a secured table scopes, and every :system claim holds."
