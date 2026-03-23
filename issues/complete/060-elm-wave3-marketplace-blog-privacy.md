# Issue #060: Elm Wave 3 — Marketplace (Classifieds), Blog, Privacy Settings

## Summary
Build the Elm pages for marketplace classifieds (listing creation with contact info, listing detail, browse), blog (editor, archive, post detail with book associations), and privacy settings (profile visibility, shelf overrides, View As mode).

## User Stories
US-7.1 (listing creation — classifieds model per ADR 013), US-12.1.1 (blog editor), US-12.1.2 (LLM associations display), US-12.1.3 (browse blog), US-10.1.1 (profile visibility), US-10.2.1 (shelf visibility), US-10.3.1 (View As)

**Deferred (ADR 013):** US-7.2 (purchase flow), US-7.3 (shipping)

## Goal
Users can list books for sale with contact info for off-platform communication, write blog posts, and manage their privacy settings — all through the Elm frontend.

## Technical Requirements

**Marketplace pages (classifieds model — no payments, no shipping):**
- `Page.Marketplace.CreateListing` — book selector (from user's placements), condition grader (5 values: new, like_new, good, fair, poor), pricing mode (fixed/offer), price input (ZAR), contact info field (email/phone/WhatsApp), description, photo URLs
- `Page.Marketplace.ListingDetail` — book metadata, condition, price, seller contact info (visible on active listings), description, listing status badge
- `Page.Marketplace.Browse` — grid/list of active listings, sorted by listed_at desc, paginated (API returns max 50)
- `Page.Marketplace.MyListings` — seller's own listings (all statuses), activate/deactivate/mark sold actions
- No checkout page, no payment widget, no shipping options, no seller onboarding

**Blog pages:**
- `Page.Blog.New` / `Page.Blog.Edit` — Markdown editor (minimal rich text: bold, italic, headings, blockquote, links), visibility selector in publish bar, "Save draft" / "Publish" buttons
- `Page.Blog.Post` — post detail with "Books from my shelves" section (top 3 LLM associations with confirm/dismiss for owner), no comments section (deferred)
- `Page.Blog.Archive` — reverse-chronological post list (title, date, first two lines, visibility icon)
- `Components.BookAssociations` — owner view: suggestions with confirm/dismiss; reader view: confirmed associations only

**Privacy settings:**
- `Page.Settings.Privacy` — profile visibility toggle (Only me / Discoverable), per-shelf visibility overrides, ceiling rule explanation
- `Components.VisibilityBadge` — padlock/globe/group icon with tooltip per visibility level
- `Components.ViewAsBar` — sticky amber banner when viewing as another perspective, "Exit preview" button

## Definition of Done
- [ ] Marketplace listing creation works with contact info and 5-value condition grading
- [ ] Listing detail shows seller contact info on active listings
- [ ] Browse page shows paginated active listings
- [ ] My Listings page shows all seller listings with state actions (activate/deactivate/sold)
- [ ] Blog editor saves drafts and publishes with visibility control
- [ ] LLM association suggestions appear after publish; confirm/dismiss works
- [ ] Blog archive displays posts in reverse-chronological order
- [ ] Privacy settings page saves profile and shelf visibility
- [ ] View As mode shows restricted content with persistent banner
- [ ] Visibility badges render on shelves and posts
- [ ] `elm-format --validate src/` passes

## Dependencies
Issues #053a (blog API — done), #054a (marketplace API — done), #047-048 (visibility API — done), #087 (marketplace sold status — needed for "mark sold" action)

## Agent Assignment
elm-agent

## Progress Notes
