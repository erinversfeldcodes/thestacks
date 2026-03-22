# Issue #060b: Elm — Blog Pages

## Summary
Build blog Elm pages: markdown editor, post detail with book associations, and archive.

## User Stories
US-12.1.1 (blog editor), US-12.1.2 (LLM associations), US-12.1.3 (browse blog)

## Goal
Users can write and publish blog posts with visibility controls. Published posts show LLM-suggested book associations that the author can confirm or dismiss.

## Technical Requirements
**`Page.Blog.New` / `Page.Blog.Edit`:**
- Markdown editor (bold, italic, headings, blockquote, links)
- Visibility selector in publish bar (owner/group/platform)
- "Save draft" / "Publish" buttons
- Edit existing via `PUT /api/blog/posts/:id`

**`Page.Blog.Post`:**
- Post body rendered as HTML (from Markdown)
- "Books from my shelves" section
- Owner view: suggestions with confirm/dismiss buttons
- Reader view: confirmed associations only
- `Components.BookAssociations` shared component

**`Page.Blog.Archive`:**
- Reverse-chronological list from `GET /api/blog/posts`
- Each: title, date, first two lines, visibility icon

## Scope Check
- Create 3 page modules + 1 component
- ~300 LOC

## Definition of Done
- [ ] Editor saves drafts and publishes
- [ ] Post detail renders markdown
- [ ] Associations confirm/dismiss works for owner
- [ ] Archive lists posts chronologically
- [ ] `elm-format --validate src/` passes

## Agent Assignment
elm-agent
