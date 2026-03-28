# Issue #143: Marketplace — Offer Threads & Q&A Context

## Summary
Implement the negotiation layer on top of fixed-price listings. Buyers can open private offer threads (counter-offer, accept, decline). Buyers and other users can ask public questions on listings. Schemas and changesets exist; this issue wires in all operations. Supplements Issue #054 (which covers fixed-price buy and Stitch Money payment).

## User Stories
US-13.2.1 Ask a Question on a Listing, US-13.2.2 Private Offer Thread, US-7.2 (offer path)

## Goal
`Stacks.Marketplace` exposes a full offer negotiation cycle: open thread → exchange messages → accept/decline/counter. Public Q&A is separate: anyone can ask; only the seller answers.

## Scope Check
- Does this issue touch more than 3 controllers? → No — implementation only.
- Does this issue add more than 2 new endpoints? → No — no endpoints in this issue.
- Does this issue exceed ~300 lines of production code? → ~250 LOC across offer + Q&A functions.
- Does this issue combine unrelated concerns? → No — both are listing communication features.

## Wiring
- [x] This issue is implementation only. Wired by issue #144.

## Technical Requirements

**`Stacks.Marketplace` additions:**

*Offer threads (private):*
```elixir
open_offer_thread(listing_id, buyer_id, attrs)
  # attrs: {initial_amount_cents, message_body}
  # → {:ok, OfferThread} | {:error, :listing_not_found | :already_open | changeset}

send_offer_message(thread_id, sender_id, attrs)
  # → {:ok, OfferMessage} | {:error, :unauthorized | :thread_closed | changeset}

accept_offer(thread_id, seller_id)
  # → {:ok, OfferThread} | {:error, :unauthorized | :already_closed}
  # Transitions listing to :pending_payment; emits offer.accepted

decline_offer(thread_id, seller_id)
  # → {:ok, OfferThread} | {:error, :unauthorized}

counter_offer(thread_id, seller_id, amount_cents)
  # → {:ok, OfferMessage} | {:error, :unauthorized | :thread_closed}

get_offer_thread(thread_id, requester_id)
  # → OfferThread with messages | {:error, :not_found | :unauthorized}
  # Only buyer and seller may view

list_offer_threads(listing_id, seller_id)
  # → [OfferThread] | {:error, :unauthorized}
```

*Public Q&A:*
```elixir
ask_question(listing_id, asker_id, body)
  # → {:ok, OfferThread} (type: :qa) | {:error, :listing_not_found | changeset}

answer_question(thread_id, seller_id, body)
  # → {:ok, OfferMessage} | {:error, :unauthorized | :already_answered}

list_questions(listing_id)
  # → [OfferThread with first answer] — no auth required; block-filtered for viewer
```

**Offer thread types:** `:private_offer`, `:qa` — stored on `offer_threads.thread_type`.

**State machine for private threads:** `open → accepted | declined | expired`

**Events emitted:** `offer.opened`, `offer.accepted`, `offer.declined`, `offer.countered`, `listing.question_asked`, `listing.question_answered`

**Block filtering:** `list_questions/1` filters Q&A from blocked users (pass `viewer_id` as optional arg).

## Reviewer Context
- `Stacks.Marketplace.OfferThread` and `OfferMessage` schemas already exist from proto.sync.
- Changeset `offer_thread_changeset/2` and `offer_message_changeset/2` already exist — do not redefine.
- `accept_offer/2` must also transition the listing state to `:pending_payment` via `Stacks.Marketplace.update_listing/2` so the fixed-price payment flow in Issue #054 can proceed.
- All monetary amounts stored as integer cents (ZAR).

## Definition of Done
- [ ] `open_offer_thread/3` returns `:already_open` when buyer already has an open thread on the listing
- [ ] `accept_offer/2` transitions listing to `:pending_payment`
- [ ] `counter_offer/3` adds a message with `message_type: :counter`
- [ ] `get_offer_thread/2` returns `:unauthorized` if requester is neither buyer nor seller
- [ ] `list_questions/1` excludes Q&A from blocked users
- [ ] `answer_question/3` returns `:already_answered` if the Q&A thread already has a seller reply
- [ ] All 6 events emitted on correct operations
- [ ] Tests cover full negotiation cycle (open → counter → accept) and rejection paths
- [ ] `just verify` passes

## Dependencies
#054 (Marketplace backend — listing state machine must be implemented first)

## Agent Assignment
elixir-agent

## Progress Notes
