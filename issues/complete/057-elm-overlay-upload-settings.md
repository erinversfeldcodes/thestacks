# Issue #057: Elm — Book Detail Overlay + Upload Verification + Settings Hub

## Summary
The three highest-impact frontend changes: convert BookDetail from a page to a dismissable overlay, add the upload verification step ("We think this is…"), and build the full settings hub with sidebar navigation.

## User Stories
US-1.4.1 (book detail overlay), US-1.1.1 (upload verification + default WishList), US-14.3.3 (user menu dropdown), US-17.1.1 (settings hub), US-17.2.1 (profile), US-17.2.2 (location), US-17.2.3 (password), US-17.3.1 (notifications)

## Goal
The book detail is an overlay that appears on top of the current page (URL unchanged, dismiss via Escape). The upload flow has a verification step before shelf placement. Settings are accessible from the user menu dropdown and have a full sidebar navigation.

## Technical Requirements

**Book detail overlay:**
- `Maybe BookDetailOverlay` in model (not a route — UI state)
- Opens on: spine click, search result click, any surface where a book appears
- Dismiss via: X button, click outside, Escape key
- URL does NOT change — browser back button works naturally
- `role="dialog"` with focus trapping (accessibility, US-19.1.1)
- Blurred background behind overlay (current shelf visible)
- Shows: editions list, per-edition prices, all current sections + "My Writing" (stub until blog exists)

**Upload verification step:**
- `UploadStep` type: `Uploading → Verifying IdentifiedBook → ChoosingShelf → Complete`
- After identification: side-by-side view — uploaded image (left) + identified book (right)
- "We think this is…" heading with book title, author, cover
- "Yes, that's it" (primary) / "No, try again" (secondary) buttons
- After verification: shelf picker with WishList pre-selected
- After placement: "[Title] added to [Shelf]" with "Add another" / "View on shelf"
- Same flow for manual ISBN entry (US-1.1.5)
- Multi-format merge prompt: "You own [Title] as [format]. Add [new format]?" (US-1.1.8)

**User menu dropdown (`Components.UserMenu`):**
- Click display name → dropdown with "Settings" and "Sign Out"
- `userMenuOpen : Bool` in model
- Click outside or Escape closes dropdown

**Settings hub (`Page.Settings`):**
- Route: `/settings` with sidebar navigation
- Sub-pages as nested routes: `/settings/profile`, `/settings/password`, `/settings/consent`, `/settings/age-verification`, `/settings/notifications`
- Sidebar highlights active sub-page
- On mobile: sidebar collapses to dropdown selector

**Sub-pages:**
- `Page.Settings.Profile` — display name, email, website URL, location (country dropdown, city input)
- `Page.Settings.Password` — current + new + confirm, strength indicator
- `Page.Settings.Notifications` — toggles per category, auto-save, ToS locked on
- `Page.Settings.Consent` — existing, ensure it fits in the new hub
- `Page.Settings.AgeVerification` — existing, ensure it fits

**`Components.OnboardingOverlay`:**
- 3-step overlay: Welcome → Upload → Shelve
- Appears after first registration (check `onboarding_completed` flag from API)
- "Skip" link always visible
- Cinematic: slow zoom into empty shelf filling with first book

## Definition of Done
- [ ] Book detail overlay opens on spine click; URL unchanged; dismiss via X/Escape/click-outside
- [ ] Focus trapped within overlay; `role="dialog"` set
- [ ] Upload shows verification step ("We think this is…") before shelf selection
- [ ] Default shelf is WishList; all 5 shelves available in picker
- [ ] Multi-format merge prompt appears when appropriate
- [ ] User menu dropdown works (Settings + Sign Out)
- [ ] Settings hub renders with sidebar navigation
- [ ] All 5 settings sub-pages render and save correctly
- [ ] Onboarding overlay appears on first registration; dismissable
- [ ] `elm-format --validate src/` passes
- [ ] `elm make src/Main.elm --optimize` succeeds with zero warnings

## Dependencies
Issue #046 (two-step upload API), Issue #048 (settings API endpoints)

## Agent Assignment
elm-agent

## Progress Notes
