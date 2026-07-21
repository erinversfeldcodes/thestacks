# The Stacks — User Stories

> An open-source, self-hosted book management and discovery platform.
> Dark-academic-meets-cottage-core aesthetic, built in Elm.

---

Phase 1 user stories have been moved to individual documentation files in `docs/user_stories/`. Each file contains the user story text plus detailed technical documentation covering UI interaction, API calls, database operations, event flows, and all stack layers. The stories below are deferred to Phase 2.

---

## 3. Third Spaces

#### US-3.1 Browse Third Spaces

**As a** user, **I want to** discover reading groups, cosy cafes, book festivals, and literary events in my area **so that** I can participate in the physical, community side of reading.

**What the user wants to accomplish:** Find real-world literary communities and spaces — reading groups, cafes with book clubs, festivals, author events — without having to search manually across platforms.

**How they accomplish it:**
1. The user clicks "Third Spaces" in the top navigation.
2. The page transitions with a fade through darkness (room transition, like the Reading Pile).
3. The Third Spaces page loads with discovered events, groups, and venues.

**What they see on the page:**
- **Aesthetic:** A cork notice board mounted on an exposed brick wall. Fairy lights are strung across the top. The overall warmth suggests a favourite cafe — perhaps the ambient sound of coffee being made if the user has enabled ambient audio.
- **Content:** Pinned flyers, cards, and notices on the cork board. Each represents a discovered event, group, or venue:
  - Reading groups (found via searches like "reading group {city} site:instagram.com")
  - Book clubs at cafes
  - Literary festivals
  - Author events at bookstores
  - Community-organised book swaps
- Each flyer card shows: event/group name, location, date (if applicable), a brief description, and a link to the original source (Instagram, Google Maps, Eventbrite, etc.).
- Events related to authors/books in the user's collection are highlighted with a warm amber border and a note: "Related to [Book Title] in your Library."
- **Location:** Country-aware with custom location settings configured by the user in their preferences (not device-based geolocation).
- **Philosophy note** (subtle, at the bottom of the page): "The Stacks encourages communities to live where they already are — on Instagram, Google Maps, Meetup. We link to them so they never depend on us."

---

## 7. Marketplace — "Looking for a New Home" (Future)

#### US-7.2 Browse and Buy a Second-Hand Book

**As a** buyer, **I want to** browse second-hand books listed by other users **so that** I can find affordable copies of books I want.

**What the user wants to accomplish:** Discover and purchase second-hand books from other Stacks users in South Africa.

**How they accomplish it:**
1. The buyer navigates to the marketplace section.
2. They browse or search for books.
3. They view a listing: condition photos, grade, price or offer option.
4. The buyer may post a public question on the listing (visible to all platform users). The seller answers publicly. Block filtering applies — blocked users cannot see each other's questions or answers.
5. For fixed-price books: they click "Buy" and proceed to checkout.
6. For open-to-offers books: they submit an offer amount via a private offer thread visible only to buyer and seller. The seller can accept, decline, or counter.
7. Payment is processed via Stitch Money (payment initiation, payouts to sellers).
8. Shipping is calculated at checkout via Pargo integration.

**What they see on the page:**
- Listing detail shows: book metadata (title, author, cover), condition photos in a small gallery, condition grade badge, seller's price or "Make an offer" button, and estimated shipping cost.
- A public Q&A section below the listing: questions and answers displayed chronologically. A "Ask a question" input at the bottom.
- Private offer thread is accessible via "Make an offer" — opens a message-style panel visible only to the two parties.
- Checkout flow: delivery address, Pargo shipping options and costs, payment via Stitch Money.
- Order confirmation with tracking information.

**Post-sale lifecycle:**
1. When payment is confirmed, the book is removed from the seller's "Looking for a Home" bookshelf. The listing is marked as "Sold" and no longer appears in marketplace search results.
2. The buyer receives a confirmation email (if notifications are enabled) and a prompt within the platform: "You've purchased [Title] by [Author]. Would you like to add it to one of your bookshelves?"
3. If the book was already on the buyer's WishList, the system detects this and offers: "This book is on your WishList. Move it to your Library or AntiLibrary?" The WishList placement is updated rather than duplicated.
4. If the book is not in the buyer's collection, they are prompted with a bookshelf picker (defaulting to AntiLibrary). Adding it is optional — the buyer may choose to dismiss the prompt.
5. The seller's placement history records the sale event: "Sold via marketplace on [date]" alongside the standard bookshelf transition history.

**What the buyer sees after purchase:**
- A warm confirmation card: "It's on its way! [Title] has found a new home." with estimated delivery date.
- Below the confirmation: "Add to your bookshelves?" with a bookshelf picker. If the book is on their WishList: "This was on your WishList! Move it to…" with Library and AntiLibrary as prominent options.
- Dismissing the prompt is fine — the book can be added later via the standard upload or ISBN entry flow.

**Refund, dispute, and non-delivery flows:** TBD — to be specified in a future phase when the marketplace is closer to implementation. The current stories define the happy path only.

---

#### US-7.3 KYC Verification for Marketplace Sellers

**As a** marketplace seller, **I want to** complete identity verification **so that** I can legally sell books and receive payouts.

**What the user wants to accomplish:** Meet the legal requirements to sell on the marketplace, with minimal personal data retained.

**How they accomplish it:**
1. Before their first listing goes live, the user is prompted to complete KYC verification.
2. The system integrates with a KYC provider (Smile Identity, Yoti, or Sumsub).
3. The user completes the verification flow (identity document + selfie).
4. Only an `identity_verified` boolean is stored — no documents are retained by The Stacks.

**What they see on the page:**
- A clear prompt: "To sell books, we need to verify your identity. This is a legal requirement. We don't store your documents — only a yes/no verification result."
- A redirect to the KYC provider's flow, then a return to The Stacks with confirmation.
- A "Verified Seller" badge appears on their listings.

---

## 9. Business & Partner Integration

The Stacks isn't just about scraping — businesses and communities should be able to **push** their information to the platform. This section covers the partner persona: independent bookshops, reading groups, cafés, and event organisers who want their offerings to appear alongside book data on The Stacks.

> **Design principle:** Partners interact through a self-service API and a lightweight dashboard. The platform owner retains approval authority over all partner content before it surfaces to readers. Partners never get access to user data — the relationship is one-directional (partner → platform).

---

### 9.1 Partner Onboarding

#### US-9.1.1 Register as a Partner

**As a** bookshop owner, **I want to** register my business with a Stacks instance **so that** I can push my inventory, events, and location to the platform.

**What the partner wants to accomplish:** Get API credentials and access to the partner dashboard so they can start syncing their data with The Stacks.

**How they accomplish it:**
1. The partner navigates to the partner registration page (linked from the Third Spaces cork board or a public `/partners` route).
2. They fill in: business name, type (bookshop / reading group / café / market / other), location (country, city, optional coordinates), website or social link, and a short description.
3. They submit the registration request.
4. The platform owner receives a notification on their Metrics Dashboard under a new "Partner Requests" section.
5. The owner reviews the request and approves or declines it.
6. On approval, the partner receives an API key and access to the partner dashboard. The owner can optionally enable manual review for all subsequent inventory and event submissions from this partner — by default, approved partners' submissions go live automatically.

**What they see on the page:**
- A clean registration form on parchment background, styled consistently with The Stacks but with a "Partner" badge in the header.
- After submission: "Your request has been sent to the curator. You'll receive an email when it's reviewed."
- The platform owner sees pending requests as index cards pinned to the Metrics Dashboard, each showing the business name, type, location, and a thumbnail of their website.

> **Host-page note (Issue #267):** The in-app owner "Metrics Dashboard" (US-5.1.1)
> that these partner-request cards were pinned to has been **superseded by the Grafana
> observability stack** (ADR-021, #236–240) and removed from the SPA. The operational-
> metrics surface is now Grafana, which is not a place to host interactive partner-
> request cards. When partner approval is built, these cards will need a new in-app home
> (e.g. a dedicated owner partner-admin page).

---

#### US-9.1.2 Manage Partner API Keys

**As a** partner, **I want to** rotate or revoke my API keys **so that** I can maintain secure access to the platform.

**How they accomplish it:**
1. The partner logs into the partner dashboard.
2. Under "API Access", they can view their current key (masked), generate a new key (which invalidates the old one), or request account deactivation.

**What they see on the page:**
- A simple key management panel showing: key prefix (first 8 chars), created date, last used date.
- A "Rotate Key" button with a confirmation dialog: "This will invalidate your current key immediately."

---

### 9.2 Inventory Sync

#### US-9.2.1 Push Book Inventory

**As a** bookshop owner, **I want to** push my current inventory to The Stacks **so that** users can see which books I have in stock and at what price.

**What the partner wants to accomplish:** Surface their available books alongside the user's bookshelves and search results, so that when a user is looking at a book, they can see "Available at [Shop Name] for R149".

**How they accomplish it:**
1. The partner sends a JSON payload to `POST /api/partner/inventory` containing a list of books, each identified by ISBN, with price, currency, condition (new/used), and quantity.
2. The payload is validated against the Protobuf-generated JSON schema: ISBN must be valid, price must be positive, condition must be from the enum.
3. Books with ISBNs already in the platform are linked immediately. Books with unknown ISBNs are queued for the standard ISBN resolution pipeline (Open Library / Google Books lookup).
4. The partner can send full snapshots or incremental updates (with an `action` field: `upsert` or `remove`).
5. All inventory data is surfaced only after the platform owner's initial approval of the partner. Subsequent inventory updates go live automatically unless the owner has enabled manual review for that partner.

**What the user sees:**
- On any book detail view, a "Available nearby" section on the cork-board sidebar shows partner shops that stock this book: shop name, price, condition, and a link to the shop's location or website.
- Availability is indicated with a small green dot on the book spine when browsing bookshelves (subtle, not intrusive).

---

#### US-9.2.2 Bulk Inventory Import via CSV

**As a** bookshop owner who doesn't have a developer, **I want to** upload a CSV of my inventory **so that** I don't need to integrate with the API directly.

**How they accomplish it:**
1. On the partner dashboard, the partner clicks "Import Inventory".
2. They upload a CSV with columns: `isbn`, `price`, `currency`, `condition`, `quantity`.
3. The system validates and previews the import: "42 books matched, 3 ISBNs not found, 1 row invalid."
4. The partner confirms, and matched books are synced as in US-9.2.1.

**What they see on the page:**
- A file upload area with a downloadable template CSV.
- A preview table showing each row's status: matched (green), pending lookup (amber), invalid (red with reason).
- A summary bar: "Ready to sync 42 books. 3 will be queued for ISBN lookup."

---

### 9.3 Events

#### US-9.3.1 Push Events

**As a** bookshop owner or reading group organiser, **I want to** advertise upcoming events (author signings, book launches, meetups) **so that** Stacks users in my area can discover them.

**What the partner wants to accomplish:** Get their events onto the Third Spaces cork board so local readers know about them.

**How they accomplish it:**
1. The partner sends a JSON payload to `POST /api/partner/events` with: title, description, date/time (ISO 8601), duration, location (address + optional coordinates), event type (signing / launch / meetup / market / reading / other), optional related ISBNs, optional image URL, and a link to RSVP or more info.
2. The event is validated and queued for display.
3. Events appear on the Third Spaces cork board, filtered by the user's country and city settings.
4. Events related to specific ISBNs also appear on those books' detail views.
5. Past events are automatically archived (moved off the board but retained in the database for analytics).

**What the user sees:**
- On the Third Spaces cork board: a new pinned card for the event, styled as a hand-lettered flyer. It shows the event title, date, location, and the partner's name. Tapping it expands to show the full description and a link out to the RSVP page.
- On a book's detail view (if ISBNs are linked): "Upcoming event: [Event Title] at [Shop Name], [Date]" in the sidebar.

---

#### US-9.3.2 Manage Events via Dashboard

**As a** partner who doesn't want to use the API, **I want to** create and manage events through a web form **so that** I can keep my listings current without technical effort.

**How they accomplish it:**
1. On the partner dashboard, the partner clicks "New Event".
2. They fill in the event form (same fields as the API payload).
3. They can edit or cancel upcoming events from a list view.
4. Cancelled events are removed from the cork board immediately.

**What they see on the page:**
- A form with date picker, location autocomplete (using the platform's existing location data), and an ISBN search field that autocompletes against known books.
- A list of their events: upcoming (editable), past (read-only), cancelled (struck through).

---

### 9.4 Third Space Listings

#### US-9.4.1 Register a Third Space

**As a** café owner, **I want to** list my venue as a reader-friendly third space **so that** Stacks users can discover cosy places to read in their area.

**What the partner wants to accomplish:** Get their café, library, wine bar, or community space onto the Third Spaces cork board as a permanent (not event-based) listing.

**How they accomplish it:**
1. The partner sends a JSON payload to `POST /api/partner/spaces` with: name, type (café / library / bar / community / other), address, coordinates, opening hours, description, amenities (wifi, power outlets, quiet, serves food/drink), and links (website, Instagram, Google Maps).
2. The platform owner approves the listing (first-time only; updates go live automatically).
3. The listing appears on the Third Spaces cork board, filtered by the user's location.

**What the user sees:**
- A permanent card on the cork board styled as a vintage postcard: the space's name, a brief description, type icon, and distance from the user's configured city.
- Tapping expands to show: full description, amenities as small icons, opening hours, and outbound links to Instagram / Google Maps / website.
- The card encourages the user to visit: "Grab a book from your Reading Pile and head to [Space Name]."

---

#### US-9.4.2 User-Submitted Third Spaces

**As a** reader, **I want to** suggest a third space I've discovered **so that** other Stacks users in my area can find it too.

**What the user wants to accomplish:** Share a cosy café or reading spot they love, even if the business hasn't registered as a partner.

**How they accomplish it:**
1. On the Third Spaces cork board, the user clicks "Pin a new space".
2. They fill in: name, type, location (city at minimum), and a link (Instagram, Google Maps, or website).
3. The suggestion is submitted to the platform owner for approval.
4. If approved, it appears as a community-submitted card (visually distinct from partner-verified listings — e.g., handwritten vs. printed style).

**What they see on the page:**
- A simple form styled as writing on a postcard.
- After submission: "Your suggestion has been pinned for the curator to review."
- Community-submitted spaces have a small "suggested by a reader" note, distinguishing them from partner-verified listings.

---

### 9.5 Partner Analytics

#### US-9.5.1 View Partner Engagement Metrics

> **Host-page note (Issue #267):** This partner-facing engagement dashboard is distinct
> from the removed in-app owner metrics dashboard (US-5.1.1, superseded by Grafana). When
> built, it will need its own partner-facing home — it cannot live on the operational
> Grafana surface.

**As a** partner, **I want to** see how many users have viewed my listings **so that** I can understand whether The Stacks is driving awareness for my business.

**What the partner wants to accomplish:** Justify the effort of keeping their listings updated by seeing aggregate (anonymised) engagement data.

**How they accomplish it:**
1. On the partner dashboard, a "Metrics" tab shows aggregate data.
2. Metrics include: inventory impressions (how many times their books appeared in "Available nearby"), event views, space card views, and outbound link clicks.
3. All data is aggregate — no individual user data is exposed. Counts are rounded to the nearest 10 to prevent fingerprinting small user bases.

**What they see on the page:**
- A simple dashboard with counters and a 30-day sparkline for each metric.
- No user identifiers, no demographics, no behavioural data. Just: "Your books were shown 140 times this month. Your event was viewed ~30 times."

---

### 9.6 Partner Content Moderation

#### US-9.6.1 Platform Owner Reviews Partner Content

**As the** platform owner, **I want to** approve or reject partner registrations and flag problematic content **so that** only quality, relevant listings appear on my instance.

**How they accomplish it:**
1. New partner registrations appear in the Metrics Dashboard under "Partner Requests".
2. The owner can approve, decline (with reason), or request changes.
3. The owner can flag any partner listing (inventory item, event, space) for removal, which immediately hides it and notifies the partner.
4. The owner can suspend a partner entirely, which hides all their content and revokes API access until reinstated.

**What they see on the page:**
- Partner requests styled as index cards with approve/decline buttons.
- A partner management table: name, type, status (active/suspended/pending), content count, last sync date.
- A content moderation queue showing flagged items from automated checks (e.g., event descriptions containing blocked keywords).

---

#### US-9.6.2 Automated Partner Content Validation

**As the** platform owner, **I want** partner-submitted content to be automatically validated **so that** obviously invalid or inappropriate content never reaches the approval queue.

**How the system handles it:**
1. All partner payloads are schema-validated (Protobuf-generated JSON schema) — malformed data is rejected at the API boundary with clear error messages.
2. Text fields (event descriptions, space descriptions) are checked against a blocklist and basic content policy (no URLs to known-bad domains, no excessive caps, no phone numbers in descriptions — those belong in the structured fields).
3. ISBNs are validated against the existing ISBN resolution pipeline.
4. Events with dates in the past are rejected.
5. Inventory with prices of 0 or negative values is rejected.
6. Validation errors are returned to the partner as structured JSON so they can fix and resubmit.

---

### 9.7 Partner Onboarding Experience

#### US-9.7.1 Partner Registration Status

**As a** partner, **I want to** check the status of my registration after applying **so that** I know whether I'm approved, pending, or need to make changes.

**How they accomplish it:**
1. After submitting the registration form (US-9.1.1), the partner receives a confirmation email with a status-check link.
2. The status page shows one of: **Pending Review**, **Changes Requested** (with the owner's notes), **Approved** (with next steps), or **Declined** (with reason).
3. If changes are requested, the partner can edit and resubmit from the same page.
4. Once approved, the page transitions to a "Welcome" state with links to the partner dashboard, API key generation, and a quick-start guide.

**What they see on the page:**
- A progress tracker: Applied → Under Review → Approved (or Declined).
- If changes requested: the owner's notes in a warm-toned callout box, with the original form fields editable below.
- If approved: a parchment-style welcome card with "Your partnership with [instance name] is confirmed" and clear CTAs for dashboard and API setup.

---

#### US-9.7.2 Partner Profile Self-Service Update

**As a** partner, **I want to** update my business details (name, description, location, operating hours, logo) **so that** readers see accurate information about my bookshop, cafe, or reading group.

**How they accomplish it:**
1. From the partner dashboard, the partner navigates to "Profile Settings".
2. They can edit: display name, description (markdown), physical address, operating hours, website URL, and upload a logo.
3. Changes take effect immediately for non-sensitive fields (description, hours, website).
4. Name and address changes require platform owner re-approval (flagged in the owner's moderation queue).
5. The partner sees a preview of how their profile appears on reader-facing pages.

**What they see on the page:**
- A form with current values pre-filled, styled consistently with the partner dashboard.
- A live preview panel showing the partner card as it appears on the Third Spaces map and book detail overlays.
- A "Pending Approval" badge next to fields that require owner sign-off, with the previously approved value still shown publicly until the new value is approved.

---

### 9.8 Reader Experience of Partner Data

#### US-9.8.1 Partner Availability on Book Detail

**As a** reader, **I want to** see which local partners have a book available **so that** I can buy it from a nearby bookshop instead of ordering online.

**How they accomplish it:**
1. On any book's detail overlay, if partner inventory data exists for that ISBN, an "Available Locally" section appears below the book metadata.
2. Each available partner is shown as a card: partner name, price (if provided), condition, and a "Visit" link to the partner's profile or website.
3. Partners are sorted by proximity if the reader has set a location preference (US-17.2.2), otherwise alphabetically.
4. If no partners carry the book, the section doesn't appear (no empty state — the absence is silent).

**What they see on the page:**
- A subtle divider with "Available at" in the same serif font as bookshelf labels.
- Partner cards styled as small index cards: partner logo (or placeholder initial), name, price in local currency, book condition as a discrete badge (New, Like New, Good, Acceptable).
- On the bookshelf view: books with local availability show a small green dot on the spine's bottom edge — unobtrusive but discoverable.

---

## 11. Social Graph

### 11.1 Groups

#### US-11.1.1 Create a Group

**As a** user, **I want to** create a group **so that** I can share content with a defined set of people using the right sharing model for my intent.

**How they accomplish it:**
1. From Profile → Groups → "New Group".
2. The user names the group and selects a type:
   - **Close friends** — bidirectional, members are aware they share a space (e.g. a trusted reading circle). Members see each other's display names in interactive spaces like comments.
   - **Broadcast** — owner pushes content to members. Members cannot see each other. Good for sharing reading notes with followers who opted in.
   - **Subscription** — members opt in to follow the owner's content. Owner accepts or ignores follow requests. Natural fit for blog readership.
3. The group is created. The owner can immediately invite members or share a join link (for subscription type).

**What they see on the page:**
- A creation flow with a group name field and three styled cards describing each type — illustrated with small vignettes consistent with the platform aesthetic.
- After creation, a group page shows: name, type badge, member count (visible to owner only for broadcast/close friends), and an "Invite" button.

---

#### US-11.1.2 Invite Members to a Group

**As a** group owner, **I want to** invite specific users to a close friends or broadcast group **so that** they can see the content I've scoped to that group.

**How they accomplish it:**
1. From the group page, the owner clicks "Invite".
2. They search for a platform user by display name and send an invitation.
3. The invited user receives a notification: "[Name] has invited you to their group '[Group name]'." They can accept or decline.
4. Accepted invitations add the user to the group. Declined invitations are silent — the owner is not notified of the decline.

**What they see on the page:**
- An invitation modal with a user search field.
- Pending invitations are shown in the group member list as "Invited" with a muted style.
- The invited user sees a notification card with "Accept" and "Decline" buttons. No pressure framing — declining feels low-stakes.

---

#### US-11.1.3 Leave a Group

**As a** group member, **I want to** leave a group **so that** I no longer receive that group's content without having to explain myself to the owner.

**How they accomplish it:**
1. From the group's page (accessible from their own Groups list), the member clicks "Leave group".
2. A confirmation: "Leave [group name]? You'll no longer see content shared with this group."
3. The member is removed. The owner receives no notification.

**What they see on the page:**
- A simple confirmation modal. No drama, no guilt framing.
- After leaving, the group disappears from the member's Groups list and any content scoped to that group becomes invisible to them.

---

#### US-11.1.4 Manage Group Members

**As a** group owner, **I want to** review and remove members from my group **so that** I can keep the group relevant and maintain control over who sees my content.

**How they accomplish it:**
1. From the group page, the owner views the member list (visible only to them).
2. They can remove any member. The removed member receives no notification and the content scoped to the group becomes invisible to them immediately.
3. For subscription groups, the owner can accept or ignore incoming follow requests.

**What they see on the page:**
- A member list with display names and join dates.
- A "Remove" option on each member row, styled as a small ghost button — present but not prominent.
- For subscription groups, a "Follow requests" tab showing pending requests with Accept/Ignore actions.

---

#### US-11.1.5 Group Content Feed

**As a** group member, **I want to** see an aggregated feed of blog posts and reading activity from other group members **so that** I can discover what people in my reading circle are writing and reading.

**What the user wants to accomplish:** Stay connected with their reading community without individually visiting each member's profile. The group page becomes a shared reading room.

**How they accomplish it:**
1. The user navigates to a group page (from their Groups list in their profile).
2. The group page shows a reverse-chronological feed of visible content from group members.
3. Feed items include: blog posts published with visibility set to this group (or broader), and bookshelf activity (books added, moved, or completed) from members whose bookshelves are visible to the group.

**What they see on the page:**
- The group page header shows: group name, type badge (close friends / broadcast / subscription), member count (for close friends groups), and an "Invite" button (for the owner).
- Below the header, a content feed styled as a stack of parchment cards:
  - **Blog posts** show: author display name, post title, first two lines, date, and a "Read" link that opens the full post.
  - **Bookshelf activity** shows: "[Name] added [Title] to their Reading Pile" or "[Name] moved [Title] to Library" — displayed as small, compact cards with the book spine thumbnail.
- For **broadcast** groups: only the owner's content appears (members are recipients, not contributors).
- For **close friends** groups: all members' content appears, creating a shared conversation.
- For **subscription** groups: the owner's content appears; members can see the feed but do not contribute to it.
- Content respects all visibility rules: a post set to "Only me" never appears, even in a close friends feed. A bookshelf set to "Only me" is excluded. The visibility ceiling (US-10.1.1) always applies.
- The feed does not use algorithmic ranking — it is strictly chronological. No infinite scroll; pagination at 20 items with a "Load more" link.

**Acceptance criteria:**
- [ ] Group pages display a reverse-chronological feed of member content
- [ ] Blog posts and bookshelf activity are included in the feed
- [ ] Content visibility rules are enforced per-item
- [ ] Broadcast groups show only the owner's content
- [ ] Close friends groups show all members' content
- [ ] Subscription groups show the owner's content
- [ ] Block filtering applies within group feeds

---

## 13. Comments

### 13.1 Blog Comments

#### US-13.1.1 Comment on a Blog Post

**As a** reader, **I want to** leave a comment on a blog post **so that** I can respond to the author's writing and participate in the conversation.

**How they accomplish it:**
1. At the bottom of any blog post they can see, the reader clicks "Leave a comment".
2. They type a comment (plain text, no rich formatting) and submit.
3. Comments are threaded — readers can reply to a specific comment, creating a sub-thread.
4. The author can delete any comment on their own post. Commenters can delete their own comments.

**What they see on the page:**
- A comment section below the book associations. Each comment shows: display name, avatar initial, timestamp, and body.
- A reply link under each comment that opens an inline reply input.
- The author's comments are marked with a subtle "(author)" label next to their name.
- Deleted comments show nothing — no `[deleted]` placeholder. The sub-thread collapses if the root comment is deleted.

---

#### US-13.1.2 Block Filtering in Comments

**As a** user, **I want** comments from users I've blocked — and comments visible to users who have blocked me — to be filtered out of every thread I read **so that** I am not exposed to people I've chosen not to interact with.

**How the platform handles it:**
- Comment threads are filtered per-viewer at render time.
- If viewer A has blocked user B (or B has blocked A), B's comments are invisible to A, and A's comments are invisible to B.
- If B's comment is the root of a sub-thread, the entire sub-thread collapses for A — not replaced with a placeholder, simply absent.
- This filtering applies silently. Neither party is aware of the other's experience.

**What they see on the page:**
- No visible indication of filtering. The thread reads as a natural conversation with no gaps or `[hidden]` markers.

---

### 13.2 Marketplace Q&A

#### US-13.2.1 Ask a Question on a Listing

**As a** buyer, **I want to** ask a public question on a book listing **so that** the seller can answer and other interested buyers can benefit from the response.

**How they accomplish it:**
1. On any open listing, the buyer scrolls to the Q&A section and clicks "Ask a question".
2. They type their question and submit. The question is immediately visible to all platform users who can see the listing (subject to block filtering).
3. The seller is notified and can respond. The answer appears beneath the question.
4. Questions and answers are visible to all viewers — they function as a public FAQ for the listing.

**What they see on the page:**
- A Q&A section below the condition photos and price. Existing questions and answers are displayed chronologically.
- The question input is at the bottom: a single text field and a "Post question" button.
- Each Q&A pair shows: asker's display name, question, seller's answer (if given), and timestamps.
- Block filtering applies: blocked users cannot see each other's questions or answers.

---

#### US-13.2.2 Private Offer Thread

**As a** buyer, **I want to** make a private offer on a book **so that** my negotiation with the seller is not visible to other buyers.

**How they accomplish it:**
1. On any open-to-offers or fixed-price listing, the buyer clicks "Make an offer" (or "Message seller").
2. An offer thread opens — a private message panel visible only to this buyer and the seller.
3. For open-to-offers: the buyer enters a ZAR amount. The seller can accept, decline, or counter.
4. For fixed-price: the thread is a general enquiry channel (e.g. "Can you confirm the edition?").
5. If the seller accepts an offer, the listing moves to checkout for that buyer and is marked as pending.

**What they see on the page:**
- A slide-in message panel styled as a private correspondence thread: warm paper background, handwritten-style dividers between messages.
- Offer amounts are shown as styled chips: buyer offer in one colour, seller counter in another.
- Accept and Decline buttons appear on the seller's view next to each buyer offer.
- "Pending" badge appears on the listing spine for all other viewers once an offer is accepted.
