# Issue #387: Wave 8 story specs — pull the D2 / US-15.1.1 / US-18.1.1 amendments forward from #320

## Summary
Wave 8 (#318) must build onboarding, the authed home, and the Looking-for-a-Home shelf — but the
stories those surfaces implement are the three amendments parked in the Wave 10 docs epic (#320,
phases 2–3). Building against a stale or self-denying story is exactly the drift Wave 10 exists to
fix, so per the owner's decision (2026-08-05) the three specs Wave 8 depends on are pulled forward
and settled BEFORE 8b/8c-homes build. #320 keeps the rest of its scope and simply records these as
already-done when it runs.

This is **spec-before-build**: the story files are the experiential bar the child PRs are held to.

## User Stories
This issue amends three existing stories (it writes no new feature):
- **US-14.1.2** — first-run onboarding
- **US-15.1.1** — the authenticated home
- **US-18.1.1** — the fifth shelf (Looking for a Home)

## Goal
Each of the three stories describes, in its "What they see" register, the surface Wave 8 will
actually build — matching the owner rulings recorded below — so 8b (onboarding) and 8c-homes have a
truthful spec to build to and a bar to be reviewed against.

## Scope Check
Three story-file amendments + the matching `implementation-mapping.md` rows. Documentation-only; no
code. Well within one issue. (The remainder of #320 — mapping repairs, the other story refreshes,
new launch stories, notes/config/memory — stays in Wave 10.)

## Wiring
n/a — documentation. The wiring these specs describe is built in #318.

## Owner rulings captured (2026-08-05)
1. **Onboarding (US-14.1.2) = D2 flow:** Welcome → **Upload your first book** → **Consent** → Done.
   ⚠️ **Build the step sequence to be easily adaptable in future** — steps expressed as data (an
   ordered list the view folds over), not hardcoded branches, so a step can be added, reordered, or
   removed without rewriting the flow. The story must describe the flow AND note this adaptability
   as an explicit design constraint (so the #318 child is reviewed for it).
2. **Authed home (US-15.1.1):** resolve the recorded drift — the home routes the reader into their
   collection (shelf preview / continue-reading / a persistent Add-Book CTA), not a marketing hero.
   (Proposed resolution from #318; confirm exact widgets during 8c design.)
3. **Fifth shelf (US-18.1.1):** Looking-for-a-Home joins the shelf family aesthetically — a real
   room (wallpaper/wood/label family), a pile-view of cover cards is acceptable if storied. Reconcile
   the story with the room treatment #318 proposes.

## Feature-Completeness Pre-Check
n/a — the stories are the pre-check for #318; their job is to exist and be truthful before build.

## Technical Requirements
1. Amend `docs/user_stories/US-14.1.2*.md` (and the narrative `user-stories.md` entry if present) to
   the D2 flow above, including the "What they see on the page" experiential section and the
   adaptable-steps design constraint.
2. Amend US-15.1.1 to describe the collection-routing home; delete the drift-acknowledging language
   (the story currently denies its own shipped surface).
3. Amend US-18.1.1 to describe the Looking-for-a-Home room, reconciled with #318's treatment.
4. Update the matching `implementation-mapping.md` story-by-story rows so the census stays consistent
   (coordinate with #320 phase 1 so the two don't double-edit the same lines — this issue owns only
   these three rows).

## Reviewer Context
- Stories live in TWO homes (per-file `docs/user_stories/US-*.md` AND narrative `user-stories.md`)
  at two ID granularities — amend both where both exist (the #320 census pitfall).
- `notes/` is gitignored / absent in worktrees — do this in the main tree.
- The experiential "What they see" section is the load-bearing part: it is the bar #318's ux-review
  quotes. Write it in the Register-A discipline (the `US-1.2.1` files are the exemplar).
- Do NOT invent scope beyond the owner rulings above — anything else discovered is a question, not a
  story edit.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Census | yes | ❌ three-way census clean for these three stories (no self-denial, mapping rows consistent) |
| Links | yes | ❌ mapping rows cite real files/components |
| 1–13 | no | n/a — documentation |

## Definition of Done
- [x] US-14.1.2 describes the D2 flow + the adaptable-steps constraint, with an experiential section — evidence: rewritten to Welcome→Upload→Consent→Done; the data-driven-steps requirement is AC #2 (verbatim: "an ordered list of step descriptors the view folds over, NOT hardcoded branches … reviewed acceptance criterion"); §12 now describes `steps : List Step` + `currentIndex`.
- [x] US-15.1.1 no longer denies the shipped home; describes collection-routing — evidence: `grep -niE "known drift|auto-redirect|confirm the need"` → clean; §1 now "two faces of one route", authed = shelf preview / continue-reading / persistent Add-Book CTA (reusing existing bookshelf reads, no bespoke endpoint).
- [x] US-18.1.1 describes the Looking-for-a-Home room, reconciled with #318 — evidence: §1/§12 now "a real room in the shelf-room family (wallpaper/wood/brass-label/lamplight), pile-view staged inside it"; data/API/age-gate sections untouched.
- [x] `implementation-mapping.md` rows for the three updated and consistent — evidence: diff scoped to the US-14.1.2 / US-15.1.1 / US-18.1.1 rows only (other US-IDs in the diff are dependency citations inside those rows, not separate edits); the rest left for #320.
- [x] `staff-review` verdict recorded below

## Dependencies
- Pulled forward from **#320** (phases 2–3); #320 records these as done when it runs. Reason: spec-before-build for Wave 8.
- **Precedes #318** phases 8b (onboarding) and 8c-homes. Reason: the story is the build's spec and review bar.
- Owner rulings above are the only design input required; all three are settled (2026-08-05).

## Agent Assignment
docs/elm-agent (experiential story authoring); owner reviews the amended story files.

## Progress Notes
Filed 2026-08-05. Pulled forward from #320 per the owner's Wave 8 kickoff decision, so onboarding and
the homes build against a truthful spec rather than a self-denying one. About-page copy (the other
Milestone B content input for 8c) is drafted for owner editing at `plans/318-about-page-copy-draft.md`.

**Implemented + staff-review: LGTM** (2026-08-05). All three stories amended and the mapping updated;
diff reviewed and verified scoped to the three stories' own rows (the other US-IDs in the mapping diff
are dependency citations inside those rows). The load-bearing wins: US-14.1.2's data-driven-steps
constraint is a *reviewed* acceptance criterion, not prose (the #318 onboarding child must be built and
reviewed for it); US-15.1.1's authed home reuses existing `GET /api/bookshelves/:name` reads rather
than a bespoke endpoint (no new surface to secure); US-18.1.1 keeps the pile-view but stages it inside
the shelf-room family. Two honest corrections by the author: the consent story is `US-8.3` (US-8.1.3 is
file-less) — both cited; and the narrative `user-stories.md` has no entries at these IDs, so the per-file
docs are the single home. No code touched. This unblocks #318 phases 8b (onboarding) and 8c-homes.
