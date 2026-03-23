# Issue #061b: Elm — RSS Feed Links on Shelves

## Summary
Add RSS feed link component to public bookshelf pages.

## User Stories
US-6.1 (RSS feeds)

## Goal
Public shelves display an RSS icon that reveals the feed URL for subscription.

## Technical Requirements
- `Components.RSSLink` — small RSS icon in shelf header
- Brass/wood aesthetic matching platform design
- Click reveals feed URL + explanation text: "Subscribe in your RSS reader"
- Only shown when shelf visibility is `platform`
- Feed URL: `/api/feeds/:user_id/:bookshelf_name`
- Copy-to-clipboard button for the URL

## Scope Check
- Create 1 component
- Modify `Page.Bookshelf` (add to header)
- ~60 LOC

## Dependencies
None (feed API exists from #056)

## Definition of Done
- [ ] RSS icon appears on platform-visible shelves
- [ ] Click reveals correct feed URL
- [ ] Copy button works
- [ ] Hidden on non-platform shelves
- [ ] `elm-format --validate src/` passes

## Agent Assignment
elm-agent
