# Issue #105: Book Detail "My Writing" Section

## Summary
Add an endpoint that returns a user's blog posts associated with a specific book. Powers the "My Writing" section in the book detail overlay (#057).

## User Stories
US-1.4.1 — Book detail overlay includes "My Writing" section showing the user's blog posts that reference this book.

## Goal
When viewing a book's detail, the authenticated user sees their own blog posts that are associated with that book (via PostBookAssociation).

## Scope Check
- 1 new endpoint or extend existing BookController.show response
- 1 context function
- ~50 LOC

## Technical Requirements

**Option A: Extend BookController.show**
- When authenticated, include `my_writing: [%{id, title, published_at}]` in the book detail response
- Query PostBookAssociation joined to Post where post.user_id = current_user and association.book_id = book_id and association.visible = true

**Option B: Separate endpoint**
- `GET /api/books/:id/posts` — returns the current user's posts associated with this book

**Context (`Stacks.Blog`):**
- `list_posts_for_book_by_user/2` — accepts book_id and user_id, returns visible associations

## Definition of Done
- [ ] Authenticated users see their writing associated with a book
- [ ] Only visible (confirmed) associations are returned
- [ ] Unauthenticated users don't see the section
- [ ] Tests cover authenticated, unauthenticated, no associations
- [ ] `just verify` passes

## Priority
Required before #057 (book detail overlay)

## Agent Assignment
elixir-agent
