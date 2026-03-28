# Issue #144: Marketplace — Offer Thread API & Elm UI

## Summary
Expose the offer thread and Q&A context (Issue #143) over HTTP and build the Elm negotiation panel on the listing detail page. Covers the buyer-facing offer flow and the seller-facing offer management view.

## User Stories
US-13.2.1, US-13.2.2, US-7.2

## Goal
A buyer can open an offer thread, exchange messages, and receive confirmation when the seller accepts. A seller can view all open offers on their listing, accept, decline, or counter. Public Q&A appears below the listing for all visitors.

## Scope Check
- Does this issue touch more than 3 controllers? → No — `OfferThreadController`, `ListingQuestionController`.
- Does this issue add more than 2 new endpoints? → Yes (5 endpoints) — acceptable for a bounded negotiation domain.
- Does this issue exceed ~300 lines of production code? → Borderline; split Elm and Elixir if needed.
- Does this issue combine unrelated concerns? → No — all listing communication.

## Wiring
- [x] This issue includes router wiring and is user-facing when complete.

## Technical Requirements

**Routes:**
```
scope "/api", StacksWeb do
  pipe_through [:api, :auth]

  post   "/listings/:listing_id/offers",              OfferThreadController, :create
  get    "/listings/:listing_id/offers",              OfferThreadController, :index  # seller only
  get    "/offers/:id",                               OfferThreadController, :show
  post   "/offers/:id/messages",                      OfferThreadController, :send_message
  put    "/offers/:id/accept",                        OfferThreadController, :accept
  put    "/offers/:id/decline",                       OfferThreadController, :decline

  # Public Q&A (no auth required for GET)
  get    "/listings/:listing_id/questions",           ListingQuestionController, :index
  post   "/listings/:listing_id/questions",           ListingQuestionController, :ask
  post   "/listings/:listing_id/questions/:id/answer", ListingQuestionController, :answer
end
```

**Elm additions (`Page.ListingDetail`):**
- Offer panel (buyers): shows current offer state; input for initial offer amount + message; message thread once open
- Offer management panel (sellers): list of open offers; accept/decline/counter controls
- Q&A section (all visitors): question list with "Ask a question" form below

**Elm state for offer panel:**
```elm
type OfferState
    = NoOffer
    | OpeningOffer
    | OfferOpen Thread
    | OfferAccepted
    | OfferDeclined
```

## Reviewer Context
- `OfferThreadController` should check if the requester is buyer or seller and route to the appropriate context function.
- Q&A `index` endpoint does not require auth; `ask` and `answer` do.
- Offer message thread renders similar to a chat: sender name, timestamp, message body, message type badge (counter/regular).

## Definition of Done
- [ ] Buyer can open an offer and see the thread update in real-time (polling or page refresh)
- [ ] Seller accept transitions listing to pending_payment and disables further offers
- [ ] Q&A renders for unauthenticated visitors
- [ ] Auth guard on offer creation returns 401 for unauthenticated
- [ ] Integration tests for all endpoints (happy + auth error paths)
- [ ] Elm unit tests for all OfferState transitions
- [ ] `just verify` passes

## Dependencies
#143 (Offer thread context), #054 (Listing CRUD)

## Agent Assignment
elixir-agent, elm-agent

## Progress Notes
