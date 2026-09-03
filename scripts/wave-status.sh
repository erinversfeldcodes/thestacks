#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1

SLUG="${1:-}"
WAVE_FILTER=""
NEXT_ONLY=0
shift_count=0
[[ -n "$SLUG" && "$SLUG" != --* ]] && shift_count=1
[[ $shift_count -eq 1 ]] && shift || SLUG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wave) WAVE_FILTER="${2:-}"; shift 2 ;;
    --next) NEXT_ONLY=1; shift ;;
    *) shift ;;
  esac
done

if [[ -z "$SLUG" ]]; then
  STATE_FILE="$(ls -t plans/*campaign*-state.json 2>/dev/null | head -1)"
else
  STATE_FILE="plans/${SLUG}-state.json"
fi

if [[ -z "${STATE_FILE:-}" || ! -f "$STATE_FILE" ]]; then
  cat >&2 <<MSG
wave-status: no campaign state file found${SLUG:+ for slug '$SLUG'}.

A campaign MUST emit plans/<slug>-state.json at Stage 6, alongside the prose plan. Without
it, wave completion is unverifiable and the harness falls back to asking a human — which is
the failure this script exists to remove. See docs/agents/staff-engineer-agent.md → Mode E.
MSG
  exit 2
fi

python3 - "$STATE_FILE" "$WAVE_FILTER" "$NEXT_ONLY" <<'PY'
import json, os, re, sys, glob

state_file, wave_filter, next_only = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
next_only = next_only
try:
    state = json.load(open(state_file))
except Exception as e:
    print(f"wave-status: {state_file} is not valid JSON: {e}", file=sys.stderr)
    sys.exit(2)

DONE = {"complete", "done"}
EVIDENCE = re.compile(
    r'`[^`]+`|_test\.(exs|ex)|\.spec\.ts|[0-9]{4}-[0-9]{2}-[0-9]{2}|#[0-9]+'
    r'|[0-9]+ (tests?|passed|panels?|series|failures?|families|checks?)|evidence:|proven:'
)

def issue_path(num):
    hits = glob.glob(f"issues/{int(num):03d}-*.md") + glob.glob(f"issues/complete/{int(num):03d}-*.md")
    return hits[0] if hits else None

def epic_rollup(num):
    """Walk the hierarchy the orchestrator already maintains, so this script reports the real
    state instead of a second opinion about it:

        campaign state (this file)  ->  plans/<root>-<slug>-epic-state.json  ->  plans/NNN-*-state.json

    A wave becomes ONE epic issue; epic mode spins out children and records them in `children`
    with `depends_on` / `merged`; each child has its own per-phase state file. Returns a
    one-line summary, or None when the item is not an epic (a plain issue, or not started).
    """
    hits = glob.glob(f"plans/{int(num)}-*-epic-state.json")
    if not hits:
        return None
    try:
        epic = json.load(open(hits[0]))
    except Exception:
        return f"epic state unreadable: {hits[0]}"
    children = epic.get("children") or {}
    done = [c for c, v in children.items() if (v.get("status") or "").lower() in DONE]
    merged = [c for c, v in children.items() if v.get("merged")]
    blocked = [c for c, v in children.items() if (v.get("status") or "").lower() == "blocked"]
    phases = []
    for cnum, cval in children.items():
        sf = cval.get("state_file")
        if sf and os.path.exists(sf):
            try:
                cs = json.load(open(sf))
                ph = cs.get("phases") or {}
                cdone = sum(1 for v in ph.values() if (v.get("status") or "").lower() in DONE)
                if ph:
                    phases.append(f"#{cnum} {cdone}/{len(ph)}ph")
            except Exception:
                pass
    bits = [f"children {len(done)}/{len(children)} done, {len(merged)} merged"]
    if blocked:
        bits.append(f"blocked: {', '.join(sorted(blocked))}")
    if epic.get("ready_set"):
        bits.append("ready: " + ", ".join(str(x) for x in epic["ready_set"]))
    if phases:
        bits.append(" ".join(phases))
    if epic.get("discovered_issues"):
        bits.append(f"discovered mid-epic: {len(epic['discovered_issues'])}")
    bits.append("PR opened" if epic.get("pr_opened") else "PR not opened")
    return " | ".join(bits)

def dod_boxes(path):
    """Returns (unchecked, checked_without_evidence) from the Definition of Done section.

    A DoD item is the `- [x]` line PLUS its indented continuation lines — evidence tokens routinely
    land on the next line, because an evidence citation is usually longer than the criterion. Reading
    only the first line reported a false "no evidence token" on a box whose proof was one line below.
    """
    items, in_dod, current = [], False, None
    for raw in open(path, encoding="utf-8"):
        if raw.startswith("## "):
            in_dod = raw.strip().lower().startswith("## definition of done")
            if current:
                items.append(current)
                current = None
            continue
        if not in_dod:
            continue
        stripped = raw.strip()
        if stripped.startswith(("- [ ]", "- [x]", "- [X]")):
            if current:
                items.append(current)
            current = {"checked": stripped[3].lower() == "x", "text": stripped[5:].strip()}
        elif current is not None and raw.startswith((" ", "\t")) and stripped:
            current["text"] += " " + stripped
        elif not stripped:
            continue
        else:
            if current:
                items.append(current)
            current = None
    if current:
        items.append(current)

    unchecked = [i["text"][:90] for i in items if not i["checked"]]
    no_ev = [i["text"][:90] for i in items if i["checked"] and not EVIDENCE.search(i["text"])]
    return unchecked, no_ev

STAFF_REVIEW = re.compile(
    r"staff[- ]review\b.{0,120}?(LGTM|DESIGN CONCERNS)|(LGTM|DESIGN CONCERNS).{0,120}?staff[- ]review\b",
    re.IGNORECASE | re.DOTALL,
)

def staff_reviewed(path):
    """True when the issue records a staff-review verdict."""
    return bool(STAFF_REVIEW.search(open(path, encoding="utf-8").read()))

violations, actionable, informal = [], [], []
waves = state.get("waves") or {}
print(f"campaign: {state.get('campaign', os.path.basename(state_file))}")
print(f"state:    {state_file}")
print(f"updated:  {state.get('updated_at', '—')}\n")

for wname in sorted(waves, key=lambda w: (len(w), w)):
    if wave_filter and str(wave_filter) != str(wname):
        continue
    wave = waves[wname]
    witems = wave.get("items") or {}
    wstatus = (wave.get("status") or "unknown").lower()
    not_done = [k for k, v in witems.items() if (v.get("status") or "").lower() not in DONE]

    if wstatus in DONE and not_done:
        violations.append(
            f"WAVE {wname} is marked '{wave.get('status')}' but these items are not done: "
            + ", ".join(sorted(not_done))
        )

    mark = "OK " if wstatus in DONE and not not_done else "-- "
    print(f"{mark}Wave {wname}: {wave.get('title','')}  [{wave.get('status','unknown')}]")

    for iname in sorted(witems):
        item = witems[iname]
        istatus = (item.get("status") or "unknown").lower()
        issue_num = item.get("issue")
        note = item.get("last_action") or item.get("note") or ""
        flags = []

        if istatus in DONE:
            if not issue_num:
                if item.get("informal") and (item.get("note") or "").strip():
                    informal.append(f"{wname}/{iname}")
                    flags.append("INFORMAL(no issue file)")
                else:
                    violations.append(
                        f"  {wname}/{iname}: marked done with NO backing issue file. A work unit "
                        f"nobody can audit is not a completed work unit — give it an "
                        f"issues/NNN-*.md with a DoD, or set \"informal\": true with a `note` "
                        f"saying why it never got one."
                    )
                    flags.append("NO-ISSUE")
            else:
                p = issue_path(issue_num)
                if not p:
                    violations.append(f"  {wname}/{iname}: cites #{issue_num} but no issues/{int(issue_num):03d}-*.md exists")
                    flags.append("PHANTOM-ISSUE")
                else:
                    unchecked, no_ev = dod_boxes(p)
                    if unchecked:
                        violations.append(
                            f"  {wname}/{iname} (#{issue_num}): marked done but {len(unchecked)} DoD "
                            f"box(es) unchecked, first: \"{unchecked[0]}\""
                        )
                        flags.append(f"DOD-OPEN({len(unchecked)})")
                    if no_ev:
                        violations.append(
                            f"  {wname}/{iname} (#{issue_num}): {len(no_ev)} checked DoD box(es) carry "
                            f"no evidence token, first: \"{no_ev[0]}\""
                        )
                        flags.append(f"NO-EVIDENCE({len(no_ev)})")
                    if not staff_reviewed(p):
                        violations.append(
                            f"  {wname}/{iname} (#{issue_num}): marked done with NO staff-review "
                            f"verdict recorded. Every issue is reviewed as it is implemented; run "
                            f"the staff-review skill over its diff and record the verdict "
                            f"(LGTM / LGTM WITH NOTES / DESIGN CONCERNS) in its Progress Notes."
                        )
                        flags.append("UNREVIEWED")
        elif istatus in ("blocked",):
            flags.append("BLOCKED: " + (item.get("blocked_on") or "unspecified"))
        else:
            actionable.append((wname, iname, item))

        badge = {"complete": "  x", "done": "  x", "blocked": "  !", "in_progress": "  >"}.get(istatus, "  .")
        extra = ("  " + " ".join(flags)) if flags else ""
        ref = f" (#{issue_num})" if issue_num else ""
        print(f"{badge} {iname}{ref}: {item.get('title','')} [{item.get('status','unknown')}]{extra}")
        if note:
            print(f"      ↳ {note[:120]}")
        if issue_num:
            roll = epic_rollup(issue_num)
            if roll:
                print(f"      ⤷ epic #{issue_num}: {roll}")
    print()

pending = state.get("human_decisions_pending") or []
if pending:
    print("HUMAN DECISIONS PENDING — these, and only these, justify stopping:")
    for d in pending:
        print(f"  ? {d}")
    print()

if next_only:
    if actionable:
        w, i, item = actionable[0]
        print(f"NEXT: wave {w} / {i} — {item.get('title','')}" + (f" (#{item['issue']})" if item.get("issue") else ""))
    else:
        print("NEXT: nothing actionable — every item is done or blocked.")
    sys.exit(0)

# ---------------------------------------------------------------------------
# Stack reviews. `staff-review` deliberately covers design and test-truthfulness
# and defers standards, idiom, schema design and contract shape to the stack
# reviewers in docs/agents/reviewers/. Deferring to a reviewer that never runs is
# how an axis disappears silently: an audit of 43 issues from one campaign found
# 42 with a staff-review and ONE naming any stack reviewer, across 323 files.
# The automated gates were green the whole time, which is exactly why nobody
# noticed — they cover the mechanical half and none of the judgement.
#
# So: once anything in the campaign is complete, every stack the branch actually
# TOUCHES must carry a recorded verdict under state["domain_reviews"].
STACK_PATHS = {
    "elixir": ("apps/core/lib", "apps/core/test"),
    "elm": ("frontend/src", "frontend/tests"),
    "database": ("apps/core/priv/repo", "dbt/"),
    "contract": ("proto/",),
    "platform": ("scripts/", ".github/", "justfile", "test/platform"),
    "python": ("apps/vision",),
    "rust": ("apps/scraper",),
}


def touched_stacks():
    """Stacks the branch diff actually touches, or None if git cannot say."""
    import subprocess

    for base_ref in ("origin/main", "main"):
        try:
            base = subprocess.run(
                ["git", "merge-base", "HEAD", base_ref],
                capture_output=True, text=True, timeout=20,
            )
            if base.returncode != 0:
                continue
            files = subprocess.run(
                ["git", "diff", "--name-only", f"{base.stdout.strip()}..HEAD"],
                capture_output=True, text=True, timeout=30,
            )
            if files.returncode != 0:
                continue
            changed = [f for f in files.stdout.splitlines() if f.strip()]
            return {
                stack
                for stack, prefixes in STACK_PATHS.items()
                if any(f.startswith(pre) for f in changed for pre in prefixes)
            }
        except Exception:
            continue
    return None


# Campaign-level, so it is not reported when the caller has filtered to one wave —
# a single-wave view answering a campaign-wide question reads as a defect in that
# wave, which it is not.
if not wave_filter and any(
    (it.get("status") or "").lower() in DONE
    for w in waves.values()
    for it in (w.get("items") or {}).values()
):
    reviews = {k.lower() for k in (state.get("domain_reviews") or {})}
    stacks = touched_stacks()
    if stacks is None:
        # Never silently pass: an unanswerable check is not a satisfied one.
        violations.append(
            "  campaign: could not determine the branch diff, so stack-review coverage is "
            "UNKNOWN — not satisfied. Run from a git checkout with main reachable."
        )
    else:
        for stack in sorted(stacks - reviews):
            violations.append(
                f"  campaign: the branch touches {stack} and no {stack} review is recorded. "
                f"`staff-review` does not cover this axis — it defers standards, idiom, schema "
                f"design and contract shape to docs/agents/reviewers/{stack}-reviewer.md. Run it "
                f"over the cumulative diff for that stack and record the verdict under "
                f"\"domain_reviews\" in the campaign state."
            )

if violations:
    print("=" * 78)
    print(f"{len(violations)} UNBACKED COMPLETION CLAIM(S) — the campaign is not where it says it is:\n")
    for v in violations:
        print(v)
    print("\nFix the artifact or fix the status. Do not ask a human which it is.")
    sys.exit(1)

total = sum(len(w.get("items") or {}) for w in waves.values())
done = sum(1 for w in waves.values() for it in (w.get("items") or {}).values()
           if (it.get("status") or "").lower() in DONE)
print(f"All completion claims are backed. {done}/{total} items done, {len(actionable)} actionable.")
if informal:
    print(f"\n{len(informal)} item(s) done WITHOUT an issue file (declared informal): "
          + ", ".join(informal))
    print("Each is unauditable by design. Do not add to this list — Mode E files the issue first.")
sys.exit(0)
PY
