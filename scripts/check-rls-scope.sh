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
#
# ⛔ WHAT THIS GATE CANNOT SEE, stated here because overstating it is worse than
# the gap. Its granularity is the MODULE; the defect's granularity is the QUERY.
# A module that scopes in twenty places satisfies check 1, so a single unscoped
# read added to it passes — measured, by planting exactly that in the largest
# scoped context and getting a clean exit 0. The compile-time `Stacks.Worker`
# macro does not cover it either: that applies to workers, and the contexts are
# not workers.
#
# So the honest claim is: this gate catches a module that scopes NOWHERE and a
# worker whose `:system` declaration is false. It does NOT make every unscoped
# query catchable, and nothing in this repository does — the one instrument that
# caught a real one was a deployed preview stack returning HTTP 500 on every
# bookshelf write. Read "OK" below as "no module-level omission", and keep
# reviewing diffs.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

LIB="apps/core/lib/stacks"
SCHEMAS='Bookshelf|Placement|UserBlock|VisibilityGrant'
SCOPE_MARKERS='Scope\.with_user|Scope\.set!|Scope\.multi_step|Scope\.anonymous|Scope\.for_viewer|op\.blocked_pair|op\.wishlist_user_ids|op\.placement_owners_for_edition|op\.placement_owner|op\.platform_row_counts'
REPO_CALLS='Repo\.(all|one|get|get!|get_by|aggregate|exists\?|insert|insert!|update|update!|delete|delete_all|update_all|insert_all|query!|query)'

# ⛔ THE ALLOWLIST IS A CLAIM THIS SCRIPT CHECKS, NOT A SENTENCE IT PRINTS.
#
# It used to hold a free-text reason per module, echoed next to `ALLOWED`. Of
# eight entries, SEVEN were factually false — each true of *part* of its
# module's behaviour (the read half, the enqueue half, the prose half) while the
# uncovered part rode along on a true-sounding sentence. Every one was a real
# refused query on a deployed stack: the public transparency page, the admin
# dashboard, the marketplace write path, the reader insights page, the group
# feed, the visibility gate, and a feed handler that swallowed the refusal into
# a silent nil.
#
# ⚠️ What makes this worth restructuring rather than rewording: a reviewer
# briefed to be adversarial about exactly this ran the discovery predicate, got
# the complete failing set in its own output, and then cleared three modules by
# reading these reasons instead of the code. Prose beside a verdict reads as
# VERIFIED. A corrected sentence would rot the same way, because nothing
# re-checks a sentence.
#
# So an entry now names a KIND, and each kind is a check:
#
#   no-queries   the file makes no Repo call at all. Checked.
#   definer      every secured-table access goes through an `op.*` SECURITY
#                DEFINER function, and the file contains no direct query form.
#                Checked, including the pipeline and bare-schema-argument forms.
#   policy:NAME  a named policy makes this read public. Checked by grepping
#                `CREATE POLICY NAME` across priv/repo/migrations — so dropping
#                the policy turns this gate red.
#
# ⛔ What is NOT available as a kind: "delegates to something that scopes", which
# is what four of the seven false reasons claimed. It is unverifiable from one
# file, and it was wrong every time it was claimed.
#
# ⚠️ Three query forms, not one. The first draft of the textual check matched
# only `from(x in Schema)` and would have passed `visibility.ex` (pipeline head,
# `Bookshelf |> where(...)`) and `admin/data.ex` (`Repo.aggregate(Bookshelf, …)`)
# — the dominant styles in this codebase, not edge cases.
#
# ⛔ And a limit this gate cannot fix, stated because overstating it is how the
# last version did damage: a secured table reached through an ASSOCIATION ATOM
# names no schema module at the call site. `Repo.preload(placement, :bookshelf)`
# reads `op.bookshelves` with the word "bookshelves" nowhere in the line. No
# textual check reaches it; one such site existed and was found by connecting as
# the runtime role, not by any grep. The companion ExUnit check walks Ecto's
# association graph for that class. Neither is a substitute for driving the
# surfaces as the least-privilege role, which is the only instrument that found
# all seven of these.
# ⚠️ EMPTY, and that is the honest state. The eight prose entries are gone: seven
# were false, and the eighth — `events/registry.ex`, claiming "runs no query of
# its own" — was TRUE and also pointless. Discovery requires both a secured
# schema name and a Repo call, and that module makes no Repo call, so it was
# never discovered and allowlisting it excluded nothing. The anti-vacuity check
# below is what revealed that, on its first run.
#
# The lesson is the one the false seven teach from the other side: an allowlist
# entry nobody checks is not a small risk, it is an absence of information. Four
# modules that used to sit here now scope or call a definer instead; one is
# unfixed and reports MISSING, which is correct.
allow_kind() {
    # ⛔ A TEST SEAM, and it exists because emptying the allowlist left the
    # verifier below with zero coverage. `verify_kind`, `DIRECT_QUERY_FORMS`
    # and `DEFINERS` were never executed by any run, and the per-kind
    # anti-vacuity check compared 0 resolved against 0 declared and passed.
    #
    # ⚠️ The guard was written for "the pattern behind a kind stopped
    # matching". The vacuity arrived instead by **emptying the input**, which
    # it did not model — so the machinery that will decide the next allowlist
    # entry, including the three-form query matcher, had no live caller, no
    # test, and a guard that could not notice.
    #
    # ⛔ Re-adding entries to fix that would be wrong: an empty allowlist is
    # the honest state. The seam lets the suite drive each kind and each query
    # form against fixtures instead. It is read ONLY from the environment, so
    # no committed entry can hide in it.
    # ⚠️ A plain word-split loop, NOT `… | while read`. A while loop at the end
    # of a pipeline is a subshell in bash 3.2, and this function's output is
    # consumed by a command substitution — a combination that proved to behave
    # differently inside a sourced suite than standalone, for reasons not worth
    # chasing when the pipeline buys nothing.
    if [[ -n "${RLS_SCOPE_TEST_ALLOWLIST:-}" ]]; then
        local entry path kind
        local saved_ifs="$IFS"
        IFS=','
        for entry in $RLS_SCOPE_TEST_ALLOWLIST; do
            path="${entry%%=*}"
            kind="${entry#*=}"
            if [[ "$path" == "$1" ]]; then
                IFS="$saved_ifs"
                printf '%s' "$kind"
                return
            fi
        done
        IFS="$saved_ifs"
        printf '%s' ""
        return
    fi

    case "$1" in
        *) echo "" ;;
    esac
}

# The three query forms that reach a secured table by naming its schema module.
# ⚠️ Comments stripped before matching: this codebase has five recorded cases of
# an absence assertion satisfied by the prose explaining the pattern it bans.
DIRECT_QUERY_FORMS='from\([a-z_]+ in (Bookshelf|Placement|UserBlock|VisibilityGrant)|^[[:space:]]*(Bookshelf|Placement|UserBlock|VisibilityGrant)[[:space:]]*$|(Bookshelf|Placement|UserBlock|VisibilityGrant)[[:space:]]*\|>|Repo\.[a-z_!?]+\((Bookshelf|Placement|UserBlock|VisibilityGrant)[,)]'

DEFINERS='op\.blocked_pair|op\.wishlist_user_ids|op\.placement_owners_for_edition|op\.placement_owner|op\.platform_row_counts'

fail=0
checked=0
kinds_resolved=0
echo "==> Checking every module that queries a row-level-secured table"

verify_kind() {
    # $1 = relative path, $2 = file, $3 = kind. Echoes a failure reason, or
    # nothing when the claim holds.
    local rel="$1" file="$2" kind="$3" code
    code="$(sed 's/#.*//' "$file")"

    case "$kind" in
        no-queries)
            if grep -qE "$REPO_CALLS" <<<"$code"; then
                echo "claims no-queries but makes a Repo call"
            fi
            ;;
        definer)
            if ! grep -qE "$DEFINERS" <<<"$code"; then
                echo "claims definer but calls no op.* definer function"
            elif grep -qE "$DIRECT_QUERY_FORMS" <<<"$code"; then
                echo "claims definer but also queries a secured schema directly"
            fi
            ;;
        policy:*)
            local policy="${kind#policy:}"
            if ! grep -rqE "CREATE POLICY[[:space:]]+${policy}\b" apps/core/priv/repo/migrations; then
                echo "names policy '${policy}', which no migration creates"
            elif grep -qE 'Repo\.(update|update!|insert|insert!|delete|delete_all|update_all|insert_all)' <<<"$code"; then
                echo "names a read policy but writes to a secured table"
            fi
            ;;
        *)
            echo "unknown kind '${kind}' — kinds are: no-queries, definer, policy:NAME"
            ;;
    esac
}

while IFS= read -r file; do
    rel="${file#"$LIB"/}"

    grep -qE "$SCHEMAS" "$file" || continue
    grep -qE "$REPO_CALLS" "$file" || continue

    checked=$(( checked + 1 ))

    kind="$(allow_kind "$rel")"
    if [[ -n "$kind" ]]; then
        problem="$(verify_kind "$rel" "$file" "$kind")"
        if [[ -n "$problem" ]]; then
            echo "    FALSE CLAIM ${rel} — ${problem}" >&2
            fail=1
        else
            echo "    allowed ${rel} — ${kind} (checked)"
            kinds_resolved=$(( kinds_resolved + 1 ))
        fi
        continue
    fi

    # ⛔ Comments STRIPPED. This is the one grep that decides pass or fail for
    # every discovered module, and it was the only one in the file that read its
    # own prose as evidence — `verify_kind`, the `:system` worker check and the
    # `:user` worker check all strip, three correct instances beside one wrong
    # one. This repository has five recorded cases of an assertion satisfied by
    # the comment explaining the pattern it bans, and `SCOPE_MARKERS` has just
    # grown five more entries, widening exactly that surface.
    # ⛔ Stripped into a VARIABLE, then matched with a here-string — not
    # `sed … | grep -q`. Under `pipefail`, `grep -q` exits on its first match
    # and closes the pipe, `sed` takes SIGPIPE, and the PIPELINE's status
    # becomes 141 — so a file that genuinely matched took the else branch.
    # Measured: it bit `shelving.ex` and nothing else, because it is the
    # largest file here and the match comes early, so grep closed the pipe
    # while sed still had a thousand lines to write. A smaller file finishes
    # writing before grep exits and passes. A size-dependent false failure is
    # worse than a consistent one.
    code_only="$(sed 's/#.*//' "$file")"
    if grep -qE "$SCOPE_MARKERS" <<<"$code_only"; then
        echo "    ok      ${rel}"
    else
        echo "    MISSING ${rel} — queries a row-level-secured table and establishes no scope" >&2
        fail=1
    fi
done < <(find "$LIB" -name '*.ex' -type f ! -path '*/gen/*' | sort)

# ⛔ Anti-vacuity for the kinds themselves, not just for discovery. If the
# pattern behind a kind stops matching — a definer renamed, a query form
# rewritten — every entry claiming that kind passes silently and this gate
# reports clean while checking nothing. The gate's own history is the argument:
# its first version errored on a bash-4 builtin and still exited 0.
declared_kinds=$(grep -cE '^[[:space:]]+"[^"]+\.ex"\) echo "' "$0" || true)
if [[ -n "${RLS_SCOPE_TEST_ALLOWLIST:-}" ]]; then
    declared_kinds=$(printf '%s' "$RLS_SCOPE_TEST_ALLOWLIST" | tr ',' '\n' | grep -c '=' || true)
fi
if (( kinds_resolved != declared_kinds )); then
    echo "FAIL: ${declared_kinds} allowlist entr(ies) declared, ${kinds_resolved} resolved." >&2
    echo "      An entry that never matched a discovered module is not being checked at all," >&2
    echo "      so it excludes nothing and tells a reader something untrue." >&2
    fail=1
fi
if (( declared_kinds > 0 )); then
    echo "    (${declared_kinds} allowlist entr(ies), all verified against the code)"
fi

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
        # Same SIGPIPE hazard as above — see the note in the module loop.
        if grep -qE "$SCHEMAS" <<<"$(sed 's/#.*//' "$file")"; then
            echo "    FALSE CLAIM ${name} — declares scope: :system but references a secured schema" >&2
            fail=1
        fi
    elif grep -q "scope: :user" "$file"; then
        # ⚠️ A job declaring `:user` with no user to scope to is a contradiction,
        # and it would surface as a 42501 at whatever hour the job runs. Checked
        # here rather than in the macro: a macro sees only the `use` options, not
        # the `perform/1` head, so it cannot tell.
        if ! grep -qE 'user_id' <<<"$(sed 's/#.*//' "$file")"; then
            case "$name" in
                goodreads_import_job.ex)
                    # Derives the user from `import.user_id`; its args carry an
                    # `import_id`, so the literal does not appear in the head.
                    echo "    ALLOWED ${name} — derives its user from the import it is given" ;;
                *)
                    echo "    NO USER  ${name} — declares scope: :user but names no user_id" >&2
                    fail=1 ;;
            esac
        fi
    else
        echo "    UNDECLARED ${name} — no scope declaration" >&2
        fail=1
    fi
done

if (( workers < 30 )); then
    echo "FAIL: only ${workers} worker(s) found; the glob has stopped matching." >&2
    exit 1
fi
echo "    (${workers} worker(s) checked)"

echo "==> Checking nothing sets the scope except Stacks.Scope"
# ⛔ A bare `SET LOCAL app.current_user_id = …` outside `Stacks.Scope` is the
# one way to defeat all of the above, and it fails in the worst possible
# manner: measured, `SET LOCAL` outside a transaction emits a WARNING and does
# NOTHING, so the code reads as wired, enforces nothing, and every query it
# guards is then refused with 42501 somewhere that does not name this as the
# cause. `Stacks.Scope` is the only place allowed to set it, because it is the
# only place that guarantees a transaction.
setters=0
while IFS= read -r file; do
    case "$file" in
        */stacks/scope.ex) continue ;;
    esac
    echo "    FORBIDDEN ${file#apps/core/lib/} — sets the scope directly; use Stacks.Scope" >&2
    setters=$(( setters + 1 ))
    fail=1
done < <(grep -rlE "app\.current_user_id" apps/core/lib 2>/dev/null | sort)

if (( setters == 0 )); then
    echo "    ok      only Stacks.Scope sets app.current_user_id"
fi

if (( fail )); then
    echo "FAIL: a query against a row-level-secured table has no scope." >&2
    echo "      Establish one with Stacks.Scope.with_user/2 (or set!/1 inside a transaction" >&2
    echo "      the caller owns), or allowlist the module here WITH the reason." >&2
    exit 1
fi

echo "OK: every module querying a secured table scopes somewhere, and every :system claim holds."
echo "    (module-level, not query-level: an unscoped read inside an otherwise-scoped"
echo "     module passes this gate. Reviewing the diff is still the only thing that"
echo "     catches that before a deployed stack does.)"
