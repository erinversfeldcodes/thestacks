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
# ══════════════════════════════════════════════════════════════════════════════
# EVERY CONSTANT AND HELPER LIVES HERE, ABOVE ALL EXECUTING CODE.
#
# ⛔ THIS BLOCK IS A STRUCTURAL FIX FOR A MISTAKE MADE FOUR TIMES IN ONE DAY.
# This file is a single top-to-bottom script, and its definitions used to be
# interleaved with the flow that uses them — so adding a check meant guessing
# whether its helpers existed yet. Four times the guess was wrong, and the
# failure mode is nasty: the new code raises `NameError`, the gate exits
# non-zero, and a test asserting `assert_exit_nonzero` PASSES. The suite went
# green on a check that had never run.
#
# ⚠️ So the rule is positional rather than a matter of care: nothing below the
# "MAIN FLOW" banner may define anything, and nothing here may execute. A
# definition added below that banner is a bug even if it happens to work today,
# because the next insertion above it will not.
# ══════════════════════════════════════════════════════════════════════════════

STACK_PATHS = {
    "elixir": ("apps/core/lib", "apps/core/test"),
    "elm": ("frontend/src", "frontend/tests"),
    "database": ("apps/core/priv/repo", "dbt/"),
    "contract": ("proto/",),
    "platform": ("scripts/", ".github/", "justfile", "test/platform"),
    "python": ("apps/vision",),
    "rust": ("apps/scraper",),
}

# ⛔ SHA RESOLUTION IS SELF-CHECKED, because the verifier I used before this had
# a blind spot EXACTLY the width of the input I gave it.
#
# MEASURED, and the coupling is the lesson rather than the fix:
#
#     git rev-parse --verify 0123456789abcdef0123456789abcdef01234567  -> rc=0, echoes it
#     git rev-parse --verify 0123456789abcdef0123456789abcdef0123456   -> rc=128
#     git rev-parse --verify 012345678901                              -> rc=128
#
# A SHORT sha is ambiguous, so git must resolve it and fails when it cannot. A
# FULL-LENGTH one is syntactically unambiguous, so git accepts it without a
# lookup — and echoes it back. The pass-through is exactly 40 characters wide.
#
# ⚠️ So **padding a sha removes the check**. I was given a short sha, expanding
# it to 40 characters was the reasonable thing to do, and expanding it is what
# turned a checked input into an unchecked one. At 39 characters my fabricated
# value would have been caught. The mistake and the blind spot were the same act.
#
# ⚠️ And the instrument was easy to trust because **its success output is its
# input**: `rev-parse --verify` echoing the string makes "it resolved" and "it
# passed through" byte-identical, so no amount of reading the output
# distinguishes them. The same family as 141 meaning both "no match" and "dead
# producer". Fifteen OKs was not weak evidence, it was ZERO evidence — a
# deliberately bad input was the only thing that could ever have produced any.
#
# `^{commit}` is the one-token fix, and the peel is load-bearing beyond
# existence: a TREE object passes bare `cat-file -e` and fails with the peel,
# and what a review ledger needs is "something I can diff from", not "these
# bytes are in the object store".
BOGUS_SHA_PROBE = "0123456789abcdef0123456789abcdef01234567"


def _resolves(sha):
    """True when `sha` names a commit this repository actually has."""
    return _git(["cat-file", "-e", f"{sha}^{{commit}}"]) is not None


def _check_sha_verifier():
    """Refuse if the resolver cannot tell a real commit from a fabricated one.

    ⛔ Run on EVERY invocation rather than only in the suite, for the reason
    `check-sigpipe-hazards.sh` carries its planted violation inline: a
    verification step is an instrument and needs the same red-run discipline as
    a gate. Fifteen consecutive OKs with no known-bad input is the same shape as
    a green absence assertion with no anti-vacuity probe.
    """
    head = _git(["rev-parse", "HEAD"])
    if not head:
        return "git cannot resolve HEAD, so no sha below could be checked"
    if not _resolves(head[0]):
        return "the resolver rejects HEAD, so it would reject every real sha"
    if _resolves(BOGUS_SHA_PROBE):
        return (
            f"the resolver ACCEPTS the fabricated sha {BOGUS_SHA_PROBE[:12]}…, so every "
            f"recorded sha below would pass without being looked up"
        )
    return None


def _stacks_for(changed):
    return {
        stack
        for stack, prefixes in STACK_PATHS.items()
        if any(f.startswith(pre) for f in changed for pre in prefixes)
    }


def touched_stacks(declared_range=None):
    """Stacks the CAMPAIGN's diff touches, or None if git cannot say.

    ⚠️ Two things this got wrong, both found while closing a missing wave-11
    review axis, and both of which made the guard report "nothing to review".

    (a) IT MEASURED THE WRONG RANGE FOR A HISTORICAL CAMPAIGN. Asked about a
        campaign whose wave merged two months ago, it diffed whatever branch is
        checked out today — so the wave whose missing review axis prompted all
        this was never going to be caught by the instrument that exists to catch
        it. A campaign state may now declare its own `diff_range`
        ("<base>..<head>"), which is the only correct instrument for work that
        has already merged.

        A declared range that git cannot read returns None (UNKNOWN) rather than
        falling back to the branch diff. Falling back is precisely how the wrong
        range came to be measured, and a quiet fallback to a wrong answer is
        worse than refusing to answer.

    (b) IT WAS BLIND TO UNCOMMITTED WORK, which is what an in-flight wave looks
        like. With ten files modified and zero commits beyond main it reported
        "0 actionable" and demanded no review at all. The in-flight path now
        unions the committed diff with the working tree — the same three legs
        the migration-safety gate uses (committed, staged+unstaged, untracked),
        for the same reason: it has to be useful in the order people actually
        work, not only after a commit.
    """
    if declared_range:
        files = _git(["diff", "--name-only", declared_range])
        if files is None:
            return None
        # ⛔ An EMPTY-but-readable range is UNKNOWN, not "nothing to review".
        # The `None` path above was given a refusal and this one was not, which
        # is the same asymmetry the sweep's legs had: the case somebody thought
        # about got a guard, the neighbouring case did not. `HEAD..HEAD` — a
        # typo resolving to one commit twice — exits 0 with no output, which
        # produced an empty stack set, which satisfied every stack-review check
        # vacuously and printed full coverage.
        if not files:
            return None
        return _stacks_for(files)

    for base_ref in ("origin/main", "main"):
        base = _git(["merge-base", "HEAD", base_ref], timeout=20)
        if not base:
            continue

        committed = _git(["diff", "--name-only", f"{base[0]}..HEAD"])
        if committed is None:
            continue

        # Working-tree legs are additive: a failure to read them must not
        # discard the committed answer, so they default to empty rather than
        # aborting the whole lookup.
        worktree = _git(["diff", "--name-only", "HEAD"]) or []
        untracked = _git(["ls-files", "--others", "--exclude-standard"]) or []

        touched = _stacks_for(set(committed) | set(worktree) | set(untracked))

        # ⛔ An EMPTY computed stack set is UNKNOWN, not satisfied — the third
        # leg of the same asymmetry the declared-range branch already refuses.
        # The caller only reaches here when some item is marked done, and "work
        # is complete but nothing under any stack path was touched" is a
        # contradiction rather than a pass: either the campaign is being asked
        # about a merged wave with no `diff_range` declared (which is what that
        # field exists for) or the checkout is not the one the work landed on.
        # Reporting full stack-review coverage for either is the failure mode
        # this whole check was added to end.
        if not touched:
            return None

        return touched

    return None


# ⛔ What invalidates a PREVIEW DRIVE, which is a different population from what
# invalidates a review. A drive is evidence about running behaviour, so it is
# spent by a change to code that runs — not by a change to a gate, a test or a
# workflow. Scripts and tests are deliberately absent: a wave that only touched
# `test/platform` has not invalidated anything a browser saw.
DRIVE_PATHS = (
    "apps/core/lib",
    "apps/core/priv/repo",
    "frontend/src",
    "frontend/css",
    "proto/",
    "apps/vision/app",
    "apps/scraper/src",
    "dbt/models",
)


# ⛔ PROVENANCE IS A KIND PLUS DETAIL, NOT FREE TEXT, and the reason is a
# measured one from this repository: a predecessor guard carried eight free-text
# allowlist reasons and SEVEN of them were untrue. Presence-only prose cannot be
# checked and cannot be falsified later, so it decays into a field people fill
# in to get past the gate.
#
# An enum buys SPECIFICITY rather than verification — nothing here can confirm
# what arrived in a message. But "quoted_from_reply" is a definite claim someone
# can be shown wrong about, where "I got this from the reviewer somehow" is not,
# and being able to be wrong in public is the whole property this field exists
# for.
#
# ⚖️ Two shapes accepted, because rows already on disk use the string form:
# either {"kind": "...", "detail": "..."} or a string whose first token before a
# colon is the kind. Anything else is refused with both spellings shown.
PROVENANCE_KINDS = ("quoted_from_reply", "reconstructed")


def _provenance_kind(value):
    """The declared kind, or None when it is absent or unrecognised."""
    if isinstance(value, dict):
        kind = value.get("kind")
    elif isinstance(value, str):
        kind = value.split(":", 1)[0].strip()
    else:
        return None
    return kind if kind in PROVENANCE_KINDS else None


# ⛔ A REVIEW LOG, NOT A SINGLE FIELD, and the reason is a measured failure of my
# own bookkeeping. `reviewed_at_sha` as one value cannot distinguish "the newest
# review" from "a review" — so an axis that had been reviewed at three later
# commits sat recorded at an earlier one, and the staleness check dutifully
# reported REVIEWED work as unreviewed. Reviewers then received ranges inflated
# with work they had already approved.
#
# ⚠️ That failure is INVISIBLE to the obvious check. An empty per-axis range
# catches OVER-recording (a sha newer than any real review); under-recording
# leaves a non-empty, healthy-looking range, so it is blind by construction.
#
# ⚖️ What makes it computable is arithmetic over the log rather than knowledge of
# any reply: **the entry treated as current must be the maximum by ancestry** —
# no other recorded entry may be a DESCENDANT of it. No new trust root, nothing
# about what arrived in a message, and it catches exactly the case above: with
# three entries at later commits, treating the earliest as current is refused.
#
# ⚠️ Per-entry provenance falls out of the same change, which matters on its own:
# with a single field a `reconstructed` value can silently overwrite a
# `quoted_from_reply` one, and the stronger claim is the one you lose.
def _review_log(entry):
    """Normalise an axis's record into a list of {sha, provenance, replied_at}.

    Accepts the append-only `reviews` list and the older single-field form, so
    rows already on disk keep working — a migration that turns every existing
    row red is a migration nobody runs.
    """
    log = entry.get("reviews")
    if isinstance(log, list) and log:
        out = []
        for item in log:
            if isinstance(item, dict) and item.get("sha"):
                out.append(item)
        return out
    sha = entry.get("reviewed_at_sha")
    if not sha:
        return []
    return [
        {
            "sha": sha,
            "provenance": entry.get("reviewed_at_sha_provenance")
            or entry.get("sha_provenance"),
            "replied_at": entry.get("reviewed_on"),
        }
    ]


def _git(args, timeout=30):
    """Run a git command, returning its stdout lines, or None on any failure."""
    import subprocess

    try:
        done = subprocess.run(
            ["git"] + args, capture_output=True, text=True, timeout=timeout
        )
    except Exception:
        return None
    if done.returncode != 0:
        return None
    return [line for line in done.stdout.splitlines() if line.strip()]



# ══════════════════════════════════════════════════════════════════════════════
# MAIN FLOW — executing code only. No definitions past this line.
# ══════════════════════════════════════════════════════════════════════════════

waves = state.get("waves") or {}

# ⛔ ANTI-VACUITY. A missing key, a renamed key and an explicitly empty `{}` all
# collapsed onto the same path here, and that path printed "All completion
# claims are backed. 0/0 items done" and exited 0. This script is the project's
# stated authority on campaign progress — ask it, never a human — so a
# malformed state file reported a fully green campaign, which is the single
# most expensive thing it could get wrong. Measured both spellings.
#
# ⚠️ The whole stack-review block below is additionally gated on "some item is
# done", so an empty `waves` silenced that check too: one typo disabled both
# halves of the file's guarantees at once.
if not waves:
    print("=" * 78)
    print(f'{os.path.basename(state_file)}: the "waves" key is missing or empty.')
    print()
    print("  Nothing was examined, so nothing can be reported as backed. A campaign")
    print("  state file with no waves is malformed, not finished — and the two")
    print("  spellings that reach here (absent key, renamed key) are exactly how a")
    print("  green report over an unread file happens.")
    print()
    print("Fix the artifact or fix the status. Do not ask a human which it is.")
    print("=" * 78)
    sys.exit(1)
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

    # ⚠️ The MIRROR of the check above, and it was missing: a wave whose every
    # item is done while its own status still says in_progress passed silently.
    # Wave 1 of the 10-13 campaign sat like that — six of six items complete,
    # every DoD ticked, every staff-review verdict recorded — and the roll-up
    # reported it as in-flight, which is the state a fresh pass reads and
    # believes. A stale state file is a defect on par with a failing test, and
    # this guard checked only the half that overclaims.
    #
    # `filed` and `not_started` waves with no items yet are not stale, so the
    # emptiness case is excluded rather than reported.
    if witems and not not_done and wstatus not in DONE:
        violations.append(
            f"WAVE {wname} is marked '{wave.get('status')}' but ALL {len(witems)} of its items "
            f"are done. Either the wave is complete and its status should say so, or an item is "
            f"marked done that is not — the roll-up is what a fresh pass reads, so an "
            f"understated wave is as misleading as an overstated one."
        )

    mark = "OK " if wstatus in DONE and not not_done else "-- "
    print(f"{mark}Wave {wname}: {wave.get('title','')}  [{wave.get('status','unknown')}]")

    # ⛔ A WAVE WHOSE VERIFICATION PREDATES ITS OWN CHANGES IS NOT VERIFIED, and
    # that is not hypothetical. One wave was marked complete on the strength of a
    # preview deploy that predated every row-level-security fix in it, plus 4122
    # passing tests run as a superuser that bypasses the policies entirely. Five
    # stack reviews then found 6 P0 and 20 P1 in that wave's own work, none of
    # which any local instrument could see. "The preview was green" decays the
    # moment anything lands after it.
    #
    # This is the review-staleness mechanism one artifact over, and it reuses
    # the same three signals for the same reasons: git must be able to READ the
    # sha, the sha must be an ANCESTOR (or the file list a diff produces is
    # meaningless), and it must carry PROVENANCE (because neither of the first
    # two can prove anyone actually drove it).
    #
    # ⚠️ THREE STATES, and only a FALSE claim is a violation. A wave with a
    # drive record that is stale is claiming something checkable and wrong, so
    # it fails. A wave with NO record is not making a claim at all — it is a
    # gap, and it is reported on every run rather than either hidden or made
    # fatal. Making absence fatal would turn every wave closed before this
    # mechanism existed permanently red, which is how a useful check gets
    # deleted; hiding it is the presence-only blindness this guard already has
    # a scar from.
    if wstatus in DONE:
        drive = wave.get("preview_drive") or {}
        if not isinstance(drive, dict):
            drive = {}
        driven_at = drive.get("at_sha") or drive.get("driven_at_sha")

        if not drive:
            print(
                f"    ⚠️ no preview drive recorded — this wave's completion rests on local "
                f"instruments only, and a superuser test role bypasses row-level security"
            )
        elif drive.get("not_driven"):
            print(f"    ⚠️ not driven, by record: {drive['not_driven']}")
        elif not driven_at:
            violations.append(
                f"  WAVE {wname}: a preview drive is recorded with no sha, so whether it covers "
                f"this wave's own changes is UNKNOWN — not satisfied. Record the commit the "
                f"drive actually ran against."
            )
        else:
            since = _git(["diff", "--name-only", f"{driven_at}..HEAD"])
            if since is None:
                violations.append(
                    f"  WAVE {wname}: the preview drive names {driven_at[:12]} and git cannot "
                    f"read it, so its currency is UNKNOWN — not satisfied."
                )
            elif _git(["merge-base", "--is-ancestor", driven_at, "HEAD"]) is None:
                violations.append(
                    f"  WAVE {wname}: the preview drive names {driven_at[:12]}, which is NOT an "
                    f"ancestor of HEAD — so it is not a commit this branch's work was driven at, "
                    f"and the file list a diff against it produces is meaningless."
                )
            else:
                raw_prov = drive.get("at_sha_provenance") or drive.get("sha_provenance")
                if _provenance_kind(raw_prov) is None:
                    said = "with no provenance" if not raw_prov else (
                        "with provenance that does not declare a recognised kind"
                    )
                    violations.append(
                        f"  WAVE {wname}: the preview drive names {driven_at[:12]} {said}. "
                        f"Set `at_sha_provenance` to one of {', '.join(PROVENANCE_KINDS)} — as "
                        f"{{\"kind\": \"quoted_from_reply\", \"detail\": \"…\"}} or the string "
                        f"\"reconstructed: …\". Ancestry cannot see a sha nobody drove, because "
                        f"such a sha is a real ancestor; and free-text prose here cannot be "
                        f"falsified later, which is how seven of eight such reasons came to be "
                        f"untrue in a predecessor guard."
                    )
                stale = [f for f in since if any(f.startswith(p) for p in DRIVE_PATHS)]
                if stale:
                    shown = ", ".join(sorted(stale)[:3])
                    more = f" (+{len(stale) - 3} more)" if len(stale) > 3 else ""
                    violations.append(
                        f"  WAVE {wname}: the preview drive is STALE — {len(stale)} file(s) of "
                        f"RUNNING code changed since it drove {driven_at[:12]}: {shown}{more}. "
                        f"Re-drive on a preview and re-record the sha, or the wave's completion "
                        f"rests on a drive that never saw this code."
                    )
                else:
                    print(f"    drive current as of {driven_at[:12]}")

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
# Campaign-level, so it is not reported when the caller has filtered to one wave —
# a single-wave view answering a campaign-wide question reads as a defect in that
# wave, which it is not.
if not wave_filter and any(
    (it.get("status") or "").lower() in DONE
    for w in waves.values()
    for it in (w.get("items") or {}).values()
):
    reviews = {k.lower() for k in (state.get("domain_reviews") or {})}
    declared_range = state.get("diff_range")
    stacks = touched_stacks(declared_range)
    if stacks is None:
        # Never silently pass: an unanswerable check is not a satisfied one.
        if declared_range:
            violations.append(
                f"  campaign: the state declares diff_range \"{declared_range}\" and git cannot "
                "read it, so stack-review coverage is UNKNOWN — not satisfied. Deliberately NOT "
                "falling back to the branch diff: measuring today's branch for a campaign that "
                "merged months ago is how a missing review axis went unreported in the first "
                "place. Fix the range or fetch the commits it names."
            )
        else:
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

        # ⛔ A RECORDED REVIEW IS NOT A CURRENT ONE, and checking only for the
        # presence of a key reproduced — inside this very guard — the failure it
        # was written to prevent.
        #
        # Measured 2026-10-21: all five core stacks carried a verdict dated
        # 2026-10-14 whose `range` was the literal text
        # "cc17d2302…..HEAD". `HEAD` is a moving target stored as a string, so
        # the row kept READING as current while 166 further commits touching 178
        # files in those stacks landed behind it. The campaign reported the
        # stack-review axis as covered for a week of work nobody reviewed, and
        # the row's own text is what made it invisible.
        #
        # So a review must record the SHA it actually saw, and any later change
        # under that stack's paths makes it stale. Staleness is a violation and
        # not a warning: the whole point of this guard is that an unreviewed axis
        # must not be reportable as a reviewed one.
        # ⛔ Before any recorded sha is believed, prove the thing that believes
        # it can disbelieve. This refuses rather than warning: a resolver that
        # cannot reject a fabricated sha makes every check below vacuous, and
        # "the shas all resolved" would then be a sentence with no content.
        verifier_fault = _check_sha_verifier()
        if verifier_fault:
            violations.append(
                f"  campaign: the sha verifier is not discriminating — {verifier_fault}. "
                f"Every recorded sha below would pass unchecked, so this is a refusal rather "
                f"than a warning. ⚠️ Use `git cat-file -e <sha>^{{commit}}`, never "
                f"`git rev-parse --verify <sha>`: the latter echoes back any 40-character hex "
                f"string without looking it up, so padding a short sha to full length removes "
                f"the check."
            )

        for stack in sorted(stacks & reviews):
            entry = (state.get("domain_reviews") or {}).get(stack) or {}
            if not isinstance(entry, dict):
                entry = {}

            log = _review_log(entry)
            current = log[-1] if log else {}
            seen = current.get("sha")

            # ⛔ A DISPATCH BASE MUST BE BYTE-EQUAL TO THE CURRENT ENTRY'S SHA.
            # Not an ancestor of it, not consistent with it — string-equal.
            #
            # ⚠️ The reviewer corrected their own framing here, and the
            # correction is the whole point. Stating the rule as a property of
            # the LOG ("no entry may be a descendant of the current one") checks
            # the log's internal consistency and ties nothing to the base
            # actually dispatched from. Non-emptiness of a range is a weak
            # signal because many WRONG bases are non-empty — but an inferred
            # base essentially cannot ACCIDENTALLY be byte-equal to a recorded
            # 40-character sha.
            #
            # Both failures this mechanism exists for would have been caught by
            # it and neither was caught by ancestry: a sha fabricated by padding
            # a short one, and a base silently substituted from the dispatch
            # head when the reply had not been read.
            dispatch = entry.get("dispatch_in_flight") or {}
            if not isinstance(dispatch, dict):
                dispatch = {}
            if dispatch and not log:
                # ⛔ THE FIRST DISPATCH HAS NO ENTRY TO MATCH, and "empty log
                # means anything goes" would be this very rule bypassed by a
                # path — the same shape as a declared count sitting below an
                # early success exit. So it is a DECLARED state, not a gap: say
                # `first_dispatch: true` and it is accepted and printed.
                if dispatch.get("first_dispatch") is True:
                    print(
                        f"    {stack}: first dispatch, no prior review to match a base against"
                    )
                else:
                    violations.append(
                        f"  campaign: the {stack} dispatch names a base with no recorded review "
                        f"to match it against. If this is genuinely the first round for this "
                        f"axis, say so with `first_dispatch: true` — an undeclared empty log is "
                        f"this rule being skipped rather than satisfied."
                    )
            elif dispatch:
                base = dispatch.get("base_sha")
                if not base:
                    violations.append(
                        f"  campaign: the {stack} dispatch records no `base_sha`, so what the "
                        f"reviewer was asked to look at is UNKNOWN — not satisfied."
                    )
                elif base != seen:
                    violations.append(
                        f"  campaign: the {stack} dispatch names base_sha {base[:12]} while the "
                        f"newest recorded review is {seen[:12]}. These must be BYTE-EQUAL, not "
                        f"merely consistent: a base that is an ancestor of the newest review "
                        f"re-sends work already approved, and one that is a descendant asks about "
                        f"work nobody has reviewed. An inferred base cannot accidentally match a "
                        f"recorded 40-character sha, which is what makes equality the check and "
                        f"ancestry not."
                    )

            # ⛔ A DISPATCH MUST RECONCILE WITH A LOGGED REPLY, and the
            # byte-equality rule above CANNOT catch the case where it doesn't.
            #
            # Measured twice in one day: a reply arrived, was acted on, and was
            # never appended to the log — four times in the first instance, then
            # once more after the mechanism above was built FOR that instance.
            # The reviewer's diagnosis is why it slipped through: base-equality
            # compares a dispatch against the newest log entry, so when the
            # dispatch is simply dropped the log stays perfectly
            # self-consistent. There is nothing left behind to be unequal to.
            # Every check above reads green on a log that is missing an entry.
            #
            # What is absent is a record of the dispatch having COMPLETED.
            # So count the rounds SENT and reconcile:
            #
            #   dispatches == len(log)      and nothing in flight  → settled
            #   dispatches == len(log) + 1  and one in flight      → awaiting
            #
            # An unlogged reply is the first form with the count one too high,
            # which is the only state that distinguishes it from a round that
            # was never sent. The counter must be DECLARED at dispatch, in the
            # same step that writes `dispatch_in_flight`: inferring it from the
            # log would make it agree with the log by construction, which is the
            # vacuity this whole block exists to escape.
            #
            # ⚠️ What this does NOT establish, stated because the baseline below
            # is easy to read as more than it is: the counts were baselined to
            # the log lengths observed when this check was written, so they
            # prove nothing about rounds before that point — `dispatches_baseline`
            # records the inferred value so the one-time inference stays visible
            # instead of passing as measurement. And a hand-edited state file can
            # always be made consistent; the defect this refuses is the accidental
            # one, which is the one that actually happened, twice.
            # ⚠️ A DECLINE IS THE THIRD OUTCOME OF A DISPATCH, and leaving it
            # out made every decline read as a lost reply. Found by a reviewer
            # DECLINING a round the same hour this check shipped: the dispatch
            # was answered, correctly, and produced no review entry — so
            # `dispatches` stayed one above the log with nothing in flight,
            # which is precisely the signature of the defect. A model that
            # cannot represent a legitimate outcome reports it as the failure it
            # most resembles.
            #
            # Declines are counted rather than logged because the log's entries
            # answer "what sha has been reviewed", and a decline reviews
            # nothing. Putting it in the log would make the newest entry's sha
            # mean two different things depending on a field.
            declines = entry.get("declines", 0)
            if not isinstance(declines, int) or isinstance(declines, bool) or declines < 0:
                declines = 0

            dispatches = entry.get("dispatches")
            baseline = entry.get("dispatches_baseline")

            # ⚠️ The counter is demanded only of an axis that HAS something to
            # reconcile — a log entry or a round in flight. MEASURED: as a
            # blanket requirement it put twelve violations onto two FINISHED
            # campaigns whose axes predate the field, which is this repo's own
            # rule ("a migration that reds every existing row is one nobody
            # runs") broken two days after writing it.
            #
            # ⛔ And this is a narrowing, not a tolerated absence, only because
            # another check closes the escape: an axis with no log and no
            # dispatch is already refused below for recording no
            # `reviewed_at_sha`, so deleting the log to escape the counter
            # trades one refusal for another rather than reaching green. Stated
            # explicitly because "absent is fine" is otherwise the exact shape
            # this block refuses one paragraph up.
            has_history = bool(log) or bool(dispatch)
            if not has_history:
                pass
            elif not isinstance(dispatches, int) or isinstance(dispatches, bool):
                violations.append(
                    f"  campaign: the {stack} axis declares no `dispatches` count, so a reply "
                    f"that arrived and was never logged is UNDETECTABLE here — the log stays "
                    f"self-consistent with the entry missing, which is exactly how this was "
                    f"produced twice. Declare the count at dispatch, alongside "
                    f"`dispatch_in_flight`."
                )
            # ⛔ The baseline is MANDATORY, not optional. It was `elif
            # isinstance(baseline, int) and …`, so deleting the field silently
            # removed the only guard against a counter reset to match a short
            # log — the same shape as a declared count sitting below an early
            # success exit, and the same shape as `EXPECTED_ENTRIES` before it
            # was moved above the parse. Every live axis carries one, so
            # requiring it costs nothing and closes the downgrade.
            elif not isinstance(baseline, int) or isinstance(baseline, bool):
                violations.append(
                    f"  campaign: the {stack} axis declares {dispatches} dispatches with no "
                    f"`dispatches_baseline`. The baseline is what makes the count monotonic; "
                    f"without it a counter reset to agree with a short log passes unnoticed, so "
                    f"an absent baseline is a silent downgrade rather than a smaller claim."
                )
            elif dispatches < baseline:
                violations.append(
                    f"  campaign: the {stack} axis declares {dispatches} dispatches against a "
                    f"recorded baseline of {baseline}. A dispatch count only ever goes up; a "
                    f"lower one means the counter was reset rather than incremented, which "
                    f"removes the check instead of satisfying it."
                )
            else:
                expected = len(log) + declines + (1 if dispatch else 0)
                if dispatches != expected:
                    outcomes = f"{len(log)} logged replies"
                    if declines:
                        outcomes += f" and {declines} declined round(s)"
                    if dispatch:
                        detail = (
                            f"one dispatch is in flight, so the count should be one more than "
                            f"its {expected - 1} settled outcome(s)"
                        )
                    else:
                        detail = (
                            f"nothing is in flight, so every one of the {dispatches} dispatches "
                            f"should have settled as a logged reply or a recorded decline, and "
                            f"only {expected} have — a reply that was read and acted on but "
                            f"never appended is the shape that produces this"
                        )
                    violations.append(
                        f"  campaign: the {stack} axis declares {dispatches} dispatches against "
                        f"{outcomes}: {detail}."
                    )

            if not seen:
                violations.append(
                    f"  campaign: the {stack} review records no `reviewed_at_sha`, so whether it "
                    f"covers the current diff is UNKNOWN — not satisfied. A `range` ending in "
                    f"\"HEAD\" is not evidence: HEAD moves and the text does not, which is how "
                    f"this axis went unreported while 178 files changed behind it. Re-record the "
                    f"verdict with the resolved commit the reviewer actually saw."
                )
                continue

            # ⛔ COMMITTED work plus the working tree, the same union the
            # branch-diff path above uses — and its absence here was the same
            # asymmetry one leg over. `diff SHA..HEAD` sees only commits, so
            # uncommitted work in a stack's paths read as COVERED by a review
            # recorded at the current HEAD: exactly the shape this check exists
            # to refuse, in the check itself.
            #
            # Working-tree legs are additive and default to empty, so a failure
            # to read them narrows the answer rather than discarding the
            # committed one.
            committed_since = _git(["diff", "--name-only", f"{seen}..HEAD"])
            if committed_since is None:
                since = None
            else:
                worktree_since = _git(["diff", "--name-only", "HEAD"]) or []
                untracked_since = _git(["ls-files", "--others", "--exclude-standard"]) or []
                since = sorted(
                    set(committed_since) | set(worktree_since) | set(untracked_since)
                )
            if since is None:
                violations.append(
                    f"  campaign: the {stack} review names `reviewed_at_sha` {seen[:12]} and git "
                    f"cannot read it, so its currency is UNKNOWN — not satisfied. Fetch the "
                    f"commit it names or re-record the verdict."
                )
                continue

            # ⛔ The SHA is written by hand, so this check could only ever see
            # "files changed since the recorded SHA" and never "the recorded SHA
            # is wrong". That second failure is upstream of the first and real:
            # a dispatch computed against the wrong base once told four
            # reviewers their ranges were narrower than they were, and told a
            # fifth it had nothing to review when one file had changed.
            #
            # Ancestry is the independent signal available without trusting the
            # writer. A SHA that is not an ancestor of HEAD cannot be "the
            # commit this branch's work was reviewed at" — it is from another
            # branch, a discarded rewrite, or a typo that happens to resolve.
            # `diff A..HEAD` is silent about that: it compares two trees and
            # does not care whether A is behind HEAD, so a sibling commit
            # produces a plausible-looking file list.
            if _git(["merge-base", "--is-ancestor", seen, "HEAD"]) is None:
                violations.append(
                    f"  campaign: the {stack} review names `reviewed_at_sha` {seen[:12]}, which "
                    f"is NOT an ancestor of HEAD — so it is not a commit this branch's work was "
                    f"reviewed at, and the file list a diff against it produces is meaningless. "
                    f"Most likely a SHA from another branch or a rewritten history. Re-record the "
                    f"verdict with a commit that is actually on this branch."
                )
                continue

            # ⛔ THE CURRENT ENTRY MUST BE THE MAXIMUM BY ANCESTRY. Any other
            # recorded review that is a DESCENDANT of it means this axis has
            # been reviewed at a later commit than the one being treated as
            # current — so staleness is being measured from too far back, and
            # the next dispatch will hand the reviewer work they have already
            # approved.
            #
            # ⚠️ This is the half an empty-range check cannot reach. Over-
            # recording produces an empty range and is caught; under-recording
            # produces a non-empty, plausible range and is invisible without
            # comparing the log against itself.
            # ⛔ EVERY ENTRY MUST RESOLVE, not just the current one. The
            # ancestry comparison below asks `merge-base --is-ancestor` of each
            # older entry, and that command fails for a sha that does not
            # exist — which this code would read as "not a descendant" and skip
            # in silence. So a single bogus entry defeats the whole rule.
            #
            # ⛔ MEASURED, on my own record. I wrote a 40-char sha for this very
            # log having only been given the short form, inventing 32 hex
            # characters. The check I used to verify it was
            # `git rev-parse --verify <40-hex>`, which ECHOES BACK any
            # well-formed hex string instead of resolving it — so the
            # verification passed for the wrong reason, on a fabricated value,
            # inside the mechanism built to stop fabricated values.
            #
            # `cat-file -e <sha>^{commit}` is the form that actually resolves:
            # the `^{commit}` peel forces object lookup and fails when there is
            # nothing to peel.
            unresolvable = [item["sha"] for item in log if not _resolves(item["sha"])]
            if unresolvable:
                violations.append(
                    f"  campaign: the {stack} review log names "
                    f"{len(unresolvable)} commit(s) git cannot resolve: "
                    f"{', '.join(sha[:12] for sha in unresolvable)}. "
                    f"A recorded sha that resolves to nothing is either a fetch away or "
                    f"invented — and an unresolvable entry is SKIPPED by the ancestry rule "
                    f"below, so one of them defeats it. ⚠️ Verify with "
                    f"`git cat-file -e <sha>^{{commit}}`, not `git rev-parse --verify <sha>`: "
                    f"the latter echoes back any well-formed hex string."
                )

            later = [
                item
                for item in log[:-1]
                if item.get("sha")
                and item["sha"] != seen
                and _git(["merge-base", "--is-ancestor", seen, item["sha"]]) is not None
            ]
            if later:
                shown = ", ".join(sorted({item["sha"][:12] for item in later}))
                violations.append(
                    f"  campaign: the {stack} review is recorded at {seen[:12]}, but "
                    f"{len(later)} recorded review(s) sit LATER on this branch: {shown}. "
                    f"The current entry must be the newest by ancestry, or staleness is "
                    f"measured from too far back and the next dispatch re-sends work that was "
                    f"already reviewed. Append in reply order, and make the newest entry last."
                )

            # ⛔ THE SECOND HALF: the SHA must say where it came from.
            #
            # Ancestry proves the commit is on this branch. It cannot prove the
            # reviewer ever saw it — and that is the failure that actually
            # happened. A recording script set this field from the DISPATCH's
            # head_sha for three axes, which assumes the reviewer reviewed the
            # tip it was handed; two of them had replied at an earlier commit
            # and one at a different one entirely, so all three read as having
            # reviewed work they never saw. Every check here passed, because
            # each SHA was a real ancestor.
            #
            # There is no way to verify a claim about a message from inside this
            # file, so the requirement is that the claim be STATED: a recorded
            # SHA carries a provenance note saying it was quoted from the reply
            # rather than inferred. That converts a silent assumption into a
            # sentence someone has to write and can be wrong in public.
            #
            # ⚠️ NO `continue`. Every refusal above it ends the stack's checks
            # because staleness is genuinely UNCOMPUTABLE past them — an
            # unreadable diff yields no file list, and a non-ancestor SHA yields
            # a meaningless one. A missing provenance note is a different kind of
            # defect: the file list is perfectly computable, and the review can be
            # both unprovenanced AND stale. Short-circuiting here reported the
            # weaker finding and hid the stronger one — MEASURED, by breaking two
            # existing staleness cases that had been passing.
            provenance = current.get("provenance")
            if _provenance_kind(provenance) is None:
                violations.append(
                    f"  campaign: the {stack} review names `reviewed_at_sha` {seen[:12]} "
                    f"with no provenance of a recognised kind. "
                    f"Set `reviewed_at_sha_provenance` to one of "
                    f"{', '.join(PROVENANCE_KINDS)} — as "
                    f"{{\"kind\": \"quoted_from_reply\", \"detail\": \"…\"}} or the string "
                    f"\"reconstructed: …\". A SHA set from "
                    f"the dispatch head instead of the reply is the recorded failure here, and "
                    f"ancestry cannot see it because such a SHA is a real ancestor. The kind is "
                    f"an enum rather than prose because prose cannot be falsified later."
                )

            prefixes = STACK_PATHS[stack]
            stale = [f for f in since if any(f.startswith(p) for p in prefixes)]
            if stale:
                shown = ", ".join(sorted(stale)[:3])
                more = f" (+{len(stale) - 3} more)" if len(stale) > 3 else ""
                violations.append(
                    f"  campaign: the {stack} review is STALE — {len(stale)} file(s) under "
                    f"{', '.join(p.rstrip('/') for p in prefixes)} changed since it saw "
                    f"{seen[:12]}: {shown}{more}. "
                    f"Re-run docs/agents/reviewers/{stack}-reviewer.md over the new work and "
                    f"re-record the verdict with the SHA it saw."
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
