# Issue #060: Elm Wave 3 — Marketplace, Blog, Privacy Settings

## Summary
Build the Elm pages for marketplace (listing creation, detail, checkout), blog (editor, archive, post detail with book associations), and privacy settings (profile visibility, shelf overrides, View As mode).

## User Stories
US-7.1 (listing creation), US-7.2 (purchase flow), US-12.1.1 (blog editor), US-12.1.2 (LLM associations display), US-12.1.3 (browse blog), US-10.1.1 (profile visibility), US-10.2.1 (shelf visibility), US-10.3.1 (View As)

## Goal
Users can list books for sale, buy books, write blog posts, and manage their privacy settings — all through the Elm frontend.

## Technical Requirements

**Marketplace pages:**
- `Page.Marketplace.CreateListing` — condition grader (4 icons), fixed price input (ZAR), photo upload for condition evidence
- `Page.Marketplace.ListingDetail` — book metadata, condition photos, price, "Buy" button, estimated shipping
- `Page.Marketplace.Checkout` — delivery address, Pargo shipping options, Stitch Money payment widget
- `Page.Marketplace.SellerOnboarding` — "Connect Stitch Money Account" flow

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
- [ ] Marketplace listing creation and checkout flow works end-to-end
- [ ] Blog editor saves drafts and publishes with visibility control
- [ ] LLM association suggestions appear after publish; confirm/dismiss works
- [ ] Blog archive displays posts in reverse-chronological order
- [ ] Privacy settings page saves profile and shelf visibility
- [ ] View As mode shows restricted content with persistent banner
- [ ] Visibility badges render on shelves and posts
- [ ] `elm-format --validate src/` passes

## Dependencies
Issues #053 (blog API), #054 (marketplace API), #047-048 (visibility API)

## Agent Assignment
elm-agent

## Progress Notes
