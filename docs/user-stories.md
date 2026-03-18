# The Stacks — User Stories

> An open-source, self-hosted book management and discovery platform.
> Dark-academic-meets-cottage-core aesthetic, built in Elm.

---

## 1. Core Book Management

### 1.1 Adding a Book

#### US-1.1.1 Upload a Photo to Add a Book

**As a** user, **I want to** upload a photo or screenshot **so that** the system can identify the book and add it to my collection without manual data entry.

**What the user wants to accomplish:** Get a book into their collection by photographing it or sharing a screenshot — cover, spine, back cover, mirrored selfie-mode shot, or a screenshot from TikTok, Instagram, a reading list, or anywhere a book title or author appears as text.

**How they accomplish it:**
1. The user navigates to the Upload page (`/upload`) via the "Add a Book" link in the top navigation.
2. A drop zone is displayed. Drag-and-drop and file picker are both supported. Accepted inputs include photos of covers, spines, back covers, mirrored or rotated photos, and screenshots containing book titles or recommendations.
3. The user drops or selects one image. (For bulk upload of multiple images, see US-1.1.7.)
4. The system pre-processes the image before sending it to the vision model: orientation is corrected using EXIF data, horizontal mirroring is detected and corrected, and the image is re-encoded to a canonical format with EXIF stripped.
5. The system sends the pre-processed image to an open-source vision model (Qwen2.5-VL-7B-Instruct hosted on Modal) to extract visible text — title, author, ISBN barcode, publisher information. If the image contains multiple identifiable books, all are extracted.
6. The extracted text is used to query the Open Library API and Google Books API to resolve an ISBN.
7. **Verification step:** The system presents a side-by-side view showing the uploaded image on the left and the identified book on the right (cover image, title, author, ISBN). The message reads: "We think this is…" followed by the book details. The user confirms or rejects the identification.
8. **Shelf placement step:** On confirmation, the user is prompted to choose which shelf to place the book on. The default is WishList. A shelf picker displays all five bookshelves (Library, AntiLibrary, WishList, Reading Pile, Looking for a Home) as labelled options.
9. The book is created with full metadata and its spine slides into place on the chosen shelf with a soft thud animation. The user is shown a brief success state before being offered "Add another" or "View on shelf".

**What they see on the page:**
- The upload page (`/upload`) has a warm parchment background with a dotted border reading "Drop a photo here" in a serif typeface.
- While processing, a gentle turning-page animation shows progress with status text: "Reading the cover...", "Looking up the ISBN...", "Fetching details..."
- **Verification:** A split-view card shows the original uploaded image alongside the system's best match. The heading reads "We think this is…" in serif typeface. Below: "Is this the right book?" with "Yes, that's it" (primary) and "No, try again" (secondary) buttons. If the image contained multiple identifiable books, each is presented as a separate verification card.
- **Shelf placement:** After verification, the card transitions to a shelf picker. Each shelf is shown as a small labelled icon. WishList is pre-selected. The user taps a shelf and clicks "Add to shelf".
- On success, the card shows a brief confirmation: "[Title] added to your [Shelf Name]" with the book spine appearing in a small inline preview. Two buttons: "Add another book" (resets the upload) and "View on shelf" (navigates to the shelf page).

---

#### US-1.1.2 ISBN Hard Gate — Book Rejection

**As a** user, **I want to** receive a clear explanation when a book cannot be identified **so that** I understand why it was not added and what I can do about it.

**What the user wants to accomplish:** Understand why a book upload failed and know that this is by design — The Stacks is a physical-books-first platform that requires ISBN verification.

**How they accomplish it:**
1. The user uploads photos as in US-1.1.1.
2. The vision model extracts text but the system cannot resolve it to a valid ISBN via Open Library or Google Books.
3. The system displays a rejection message within the upload modal.

**What they see on the page:**
- The upload modal shifts to a warm amber state with an icon of a closed book.
- The message reads: "We couldn't find an ISBN for this book. The Stacks relies on ISBN to ensure accurate metadata — this is a physical-books-first platform. Try uploading a clearer photo of the back cover or barcode, or a different edition."
- Below the message, a "Try Again" button resets the upload flow and a "Cancel" button closes the modal.
- No book is created. No partial entry is saved.

---

#### US-1.1.3 Non-Book Image Rejection

**As a** user, **I want** images with no book-related content to be rejected immediately **so that** the platform remains focused on books and inappropriate content never appears.

**What the user wants to accomplish:** Upload only book-related content; accidental or intentional non-book uploads are caught before wasting processing time on them.

**What counts as book-related:** Any image from which a book title, author, or ISBN can plausibly be extracted. This includes physical book photos (cover, spine, back, barcode), mirrored or rotated photos of books, and screenshots of text that mention specific books — social media posts, reading lists, articles, captions. The classification criterion is "can we identify a book from this?" not "is this a photo of a physical book?"

**What gets rejected:** Images with no book-related content whatsoever — a pet, a landscape, food, a selfie with no book in frame, a meme with no book reference. Ambiguous images are passed through to extraction rather than rejected conservatively.

**How they accomplish it:**
1. The user uploads an image.
2. The vision model's first pass answers: "Does this image contain enough information to identify a book?"
3. If no — the image is rejected before any ISBN lookup occurs.
4. If yes or ambiguous — the image proceeds to extraction.

**What they see on the page:**
- In single-image upload: a polite rejection message: "This image doesn't seem to mention or show a book. Try a photo of the cover, spine, or back, or a screenshot where the book title appears."
- In bulk upload (US-1.1.7): the rejected image appears in the "Couldn't process" bucket on the review screen. The rest of the batch continues unaffected.
- The user can remove the image and try again with a different photo.

---

#### US-1.1.4 Age-Gated Content Flagging

**As a** user, **I want** books with sensitive content to be automatically flagged **so that** age-appropriate access controls are applied without manual moderation.

**What the user wants to accomplish:** Have the system automatically detect and flag books covering sensitive topics (anatomy, sexuality, etc.) based on their metadata.

**How they accomplish it:**
1. The user uploads a book that resolves to a valid ISBN.
2. The system retrieves the book's subjects and categories (BISAC codes, Open Library subjects).
3. The subjects are checked against a sensitive content list (nudity, anatomy, sexuality — including children's body-education books).
4. If flagged, the book is marked as age-gated (18+ only).
5. The book is still added to the shelf but requires age verification to view its detail overlay.

**What they see on the page:**
- The book spine appears on the shelf with a small, discreet frosted-glass overlay and a lock icon.
- Clicking the spine prompts age verification before the detail overlay opens.
- A notice in the upload success state reads: "This book has been marked as age-gated based on its subject matter. Age verification is required to view its details."

---

#### US-1.1.5 Manual ISBN Entry

**As a** user, **I want to** manually type an ISBN **so that** I can add a book when the vision model fails to identify it from my photos.

**What the user wants to accomplish:** Get a book into their collection even if their photos aren't clear enough for the vision model. They know the book exists and can find the ISBN on the back cover or copyright page.

**How they accomplish it:**
1. After a failed photo upload (US-1.1.2), the user clicks "Enter ISBN manually" in the rejection modal.
2. Alternatively, the user can access manual entry directly from the "Add a Book" button via a "Type ISBN instead" link below the photo upload area.
3. The user types a 10- or 13-digit ISBN.
4. The system validates the ISBN checksum client-side.
5. On submission, the system queries Open Library and Google Books for the ISBN.
6. If found, the system presents the same verification step as US-1.1.1 ("We think this is…") followed by the shelf placement prompt (defaulting to WishList).
7. If not found in either service, the system rejects the entry with the same message as US-1.1.2.

**What they see on the page:**
- A text input field styled as a library catalogue card, with a placeholder: "Enter ISBN-10 or ISBN-13".
- Real-time validation: the field border turns green when the checksum is valid, red with a hint ("Check your digits — ISBN checksums must match") when invalid.
- On successful lookup, the same verification and shelf placement flow as US-1.1.1.
- On failure, the same amber rejection state as US-1.1.2.

---

#### US-1.1.8 Multi-Format Book Merging

**As a** user, **I want** different editions and formats of the same book to be recognised as a single work **so that** my shelves don't fill up with duplicates just because I own the hardcover and the Kindle edition.

**What the user wants to accomplish:** Maintain a single, unified entry per work in their collection, with each format (hardcover, softcover, Kindle, e-book, audiobook) tracked as a variant under that entry. Each format may have its own ISBN, but the shelf placement and reading journey are shared.

**How they accomplish it:**
1. The user uploads a photo or enters an ISBN for a book format they don't yet own.
2. The ISBN resolves successfully. The system checks for an exact ISBN match first (standard duplicate detection, US-1.1.6).
3. If no exact ISBN match is found, the system checks for an existing book in the user's collection with the same title and author (fuzzy match, normalised for subtitle variations and author name ordering).
4. If a potential match is found, the system presents a merge prompt: "You own [Title] as a [existing format]. Is this the same book in [new format]?"
5. The user confirms: the new ISBN is linked to the existing book record. The corresponding format indicator is toggled on. No new shelf placement is created.
6. The user declines: the book is treated as a new entry and follows the standard upload flow (US-1.1.1 steps 8–9).

**What they see on the page:**
- The merge prompt appears as a warm blue card (consistent with the duplicate detection state) showing both editions side by side: the existing book's cover and the new format's cover (if available).
- The message reads: "You own [Title] as a [existing format]. Add the [new format] edition to the same entry?"
- Two buttons: "Yes, same book" (merges) and "No, it's different" (creates new entry).
- After merging, the book detail overlay (US-1.4.1) shows all linked ISBNs. The "Where to Buy" section displays availability and pricing per format/ISBN, so the user can see where each edition is sold.
- Format indicators on the detail overlay update to show the newly added format as filled.

---

#### US-1.1.6 Duplicate Book Detection

**As a** user, **I want to** be told when I'm adding a book that's already in my collection **so that** I don't create duplicates and can choose which shelf it belongs on.

**What the user wants to accomplish:** Avoid confusion from having the same book appear multiple times. The system should recognise the duplicate and offer helpful options.

**How they accomplish it:**
1. The user uploads photos or enters an ISBN (US-1.1.1 or US-1.1.5).
2. The ISBN resolves successfully, but a book with that ISBN already exists in the user's collection.
3. The system displays the existing book and its current shelf location.
4. The user can: (a) move the existing book to a different shelf, (b) do nothing and close the modal, or (c) view the book's detail overlay.

**Multi-format handling:** If the uploaded book resolves to a different ISBN than the existing record but represents the same underlying work (e.g., a Kindle edition of a book already owned as hardcover), the system detects this by matching on title + author. Instead of creating a duplicate, the system offers to merge: "You already own the hardcover. Would you like to add the Kindle edition to the same entry?" On confirmation, the new ISBN is linked to the existing book record and the corresponding format indicator is toggled on. The "Where to Buy" section on the detail overlay shows availability per ISBN/format. See US-1.1.8 for full multi-format merge details.

**What they see on the page:**
- The upload area shifts to a warm blue state with the existing book's cover displayed.
- The message reads: "You already have this book! It's currently on your [Shelf Name]."
- Three buttons: "Move to a different shelf" (opens shelf picker), "View book" (opens detail overlay), "Close" (dismisses).
- For multi-format matches: the message reads: "You own [Title] as a [existing format]. Add the [new format] edition?" with "Add format" (primary) and "No thanks" (secondary) buttons. Adding the format updates the book's format indicators and links the new ISBN without creating a new shelf placement.
- No new book or shelf placement is created in either case.

---

#### US-1.1.7 Bulk Image Upload with Grouping and Review

**As a** user, **I want to** drop a pile of book photos at once and review what the system found before anything lands on my shelves **so that** I can add a batch of books efficiently without losing control over what gets added.

**What the user wants to accomplish:** Upload many images in one go — including multiple photos of the same book (front, back, spine), photos of different books, screenshots of reading lists, and shelfie photos containing several titles — and have the system do the grouping work, then confirm the results before committing.

**How they accomplish it:**
1. The user clicks "Add Books" and selects multiple images, or drags a batch onto the drop zone.
2. The system accepts all images immediately and begins processing in parallel. A progress indicator shows how many images are being processed.
3. In the background, each image is classified and partially extracted. Images that resolve to the same ISBN, or have strongly overlapping title/author signals, are grouped together automatically. A shelfie or screenshot yielding multiple distinct books produces one candidate per identified book.
4. When processing is complete, the user is taken to a **Review screen**.
5. The Review screen shows one card per detected book:
   - **Confirmed** (green border): ISBN resolved cleanly. Shows thumbnail(s), title, author, ISBN badge.
   - **Ambiguous** (amber border): System found something but isn't confident. Shows best guess; user can confirm, enter ISBN manually, or dismiss.
   - **Multiple books from one image**: an expandable card showing one sub-card per detected book — the user confirms or dismisses each independently.
   - **Rejected** (grey, separate bucket): images with no detectable book content. User can dismiss or retry with a different photo.
6. The user reviews, dismisses any misidentifications, and selects which shelf each confirmed book should land on (defaulting to WishList, settable per card).
7. The user taps "Add N Books to Shelves". Each confirmed book goes through the standard ISBN resolution and duplicate detection pipeline (US-1.1.2, US-1.1.6). Any that fail at this stage surface inline on the review screen without blocking the others.
8. Successfully added books appear on their chosen shelves.

**What they see on the page:**
- The drop zone accepts any number of files. A progress bar shows "Processing N images..." as the backend works.
- The review screen uses a parchment-card grid. Cards have coloured borders by confidence state: green (confirmed), amber (ambiguous), grey (rejected).
- Each confirmed card shows the best thumbnail from the group, title in a serif typeface, author, and a shelf selector.
- A "Confirm all" button at the bottom adds all confirmed-state cards at once. Ambiguous cards must be individually confirmed or dismissed before they can be added.
- An X on each card removes it from the batch without affecting others.
- Nothing is committed to shelves until the user taps "Add to Shelves".

---

### 1.2 The Bookshelves

#### US-1.2.1 Browse the Library Shelf

**As a** user, **I want to** browse my Library shelf **so that** I can see all the books I've read, displayed as an earned collection.

**What the user wants to accomplish:** View their read books on a shelf that feels like a personal, well-worn library.

**How they accomplish it:**
1. The user clicks "Library" in the top navigation.
2. The page transitions in (horizontal slide if coming from an adjacent shelf, or a fade through darkness if coming from the Reading Pile or Third Spaces).
3. The Library shelf loads with all read books displayed as spines on floor-to-ceiling shelving.

**What they see on the page:**
- **Wallpaper:** Deep green damask wallpaper with a subtle repeating pattern.
- **Shelving:** Dark walnut panelling — rich, aged wood grain. Floor-to-ceiling bookshelves spanning the full width of the page.
- **Lighting:** Warm lamplight — a golden glow cast from the upper-left, as if from a desk lamp just out of frame. Soft shadows beneath each shelf.
- **Shelf label:** "Library" in an elegant serif typeface, centred at the top, styled as if embossed into a brass plate mounted on the wood.
- **Books:** Spines rendered vertically. Well-read and well-loved wear states dominate — rounded corners, muted colours, creased spines. Books with user writing show bookmarks/tabs poking out the top.
- The overall feeling is of a room you've earned — every spine a testament to time spent reading.

---

#### US-1.2.2 Browse the AntiLibrary Shelf

**As a** user, **I want to** browse my AntiLibrary shelf **so that** I can see all the books I own but haven't yet read, displayed as a collection of anticipation.

**What the user wants to accomplish:** View their unread-but-owned books in an environment that evokes the promise of future reading.

**How they accomplish it:**
1. The user clicks "AntiLibrary" in the top navigation.
2. The page transitions in with a horizontal slide.

**What they see on the page:**
- **Wallpaper:** Cream wallpaper with botanical prints — delicate ferns, pressed flowers, and leaf illustrations in muted greens and browns.
- **Shelving:** Lighter oak shelving — honey-toned, clean grain, less imposing than the Library's walnut.
- **Lighting:** Afternoon sunlight — a warm, diffuse glow suggesting a sun-filled room. Soft highlights on the top edges of book spines.
- **Shelf label:** "AntiLibrary" in the same serif typeface and brass plate style as other shelves.
- **Books:** Spines have a softened wear state — slight softening of edges but still relatively fresh. The promise of reading, not yet begun.

---

#### US-1.2.3 Browse the WishList Shelf

**As a** user, **I want to** browse my WishList shelf **so that** I can see all the books I aspire to own and read.

**What the user wants to accomplish:** View their desired books in a dreamy, aspirational setting.

**How they accomplish it:**
1. The user clicks "WishList" in the top navigation.
2. The page transitions in with a horizontal slide.

**What they see on the page:**
- **Wallpaper:** Watercolour floral wallpaper — soft washes of lavender, blush, sage, and cream. Loose, painterly blooms.
- **Walls:** Soft blue-grey walls visible above and below the shelving.
- **Lighting:** Morning light — cool and gentle, as if the curtains have just been drawn. A slight haze that feels aspirational, not yet fully realised.
- **Shelf label:** "WishList" on the brass plate.
- **Books:** Spines are pristine — sharp edges, clean texture, bright colours. These books are idealised; you haven't touched them yet.

---

#### US-1.2.4 Browse the Reading Pile

**As a** user, **I want to** see my currently-reading books **so that** I can feel the cosy intimacy of being mid-read.

**What the user wants to accomplish:** View the books they're actively reading in a warm, inviting setting that is distinct from the shelf metaphor.

**How they accomplish it:**
1. The user clicks "Reading Pile" in the top navigation.
2. The page transitions with a fade through darkness — a room transition, because this is a different spatial metaphor entirely.

**What they see on the page:**
- **Not a shelf.** This is a pile of books on a small side table next to an armchair. The armchair sits on a worn, warm-toned rug.
- **Setting:** An intimate reading nook. The background suggests a cosy corner — perhaps a window with rain, or a fireplace glow at the edge. The focus is the table and chair.
- **Books:** Displayed as spines in a casual, slightly haphazard pile — face-on view (you see the spine face, not looking down from above). Some lean against each other. The pile feels organic.
- **Spine wear:** Cracking — hairline cracks on spines, as if you've been bending them open nightly.
- **Future:** The armchair may eventually hold an avatar or pet (a cat, perhaps) curled up in the seat. For now, the chair is invitingly empty.
- **Shelf label:** "Reading Pile" appears as if written on a small card leaning against the base of the lamp on the side table.

---

#### US-1.2.5 Shelf Navigation Transitions

**As a** user, **I want** navigating between shelves to feel physical and spatial **so that** the experience of moving through my collection feels like walking between rooms.

**What the user wants to accomplish:** Experience seamless, immersive transitions between shelves that reinforce the physical-space metaphor.

**How they accomplish it:**
1. Clicking between adjacent shelf tabs (Library, AntiLibrary, WishList) triggers a horizontal slide transition — the current shelf slides out and the next slides in, like turning in a room to face a different wall.
2. Clicking to the Reading Pile or Third Spaces triggers a fade through darkness — the screen dims to near-black and the new space fades in, as if the user has walked down a hallway to a different room.
3. The transition duration is brief (300–500ms) — enough to feel deliberate but not enough to feel slow.

**What they see on the page:**
- Adjacent shelves: a smooth horizontal slide with a slight parallax effect on the wallpaper.
- Room transitions (Reading Pile, Third Spaces): a gentle fade to warm darkness, a beat of stillness, then the new space fades in from the centre outward.
- The top navigation remains fixed, with the active shelf tab subtly illuminated.

---

### 1.3 Spine Rendering

#### US-1.3.1 Spine Thickness by Page Count

**As a** user, **I want** book spines to vary in thickness based on page count **so that** I can visually distinguish slim novellas from doorstop epics at a glance.

**What the user wants to accomplish:** Have their shelf look realistic, with visual weight corresponding to the actual size of each book.

**How they accomplish it:**
This is automatic — no user action required. The system uses the book's page count metadata.

**What they see on the page:**
- Books under 200 pages have thin spines — a sliver on the shelf.
- Books around 300–400 pages have a standard spine width.
- Books over 600 pages have thick, commanding spines that take up noticeable shelf space.
- The thickness scale is continuous, not stepped — a 250-page book is visibly thinner than a 350-page book.

---

#### US-1.3.2 Spine Wear by Engagement

**As a** user, **I want** book spines to show wear based on my reading history **so that** my shelves tell the story of how I've engaged with each book.

**What the user wants to accomplish:** See visual evidence of their reading journey in the texture and condition of each spine.

**How they accomplish it:**
This is automatic — wear state is determined by the book's shelf and reading history.

**What they see on the page:**
- **Pristine** (WishList): Sharp edges, clean texture, vibrant colours. Untouched.
- **Softened** (AntiLibrary): Slight softening of edges and corners. Owned, handled, but unread.
- **Cracking** (Reading Pile): Hairline cracks along the spine. The book is being actively bent open.
- **Well-read** (Library, read once): Rounded corners, slightly muted colours. A book that's been through.
- **Well-loved** (Library, read multiple times): Creased spine, faded colour, dog-eared look. The most affectionate wear state.
- **Bookmarks/tabs** (any shelf, if user has written about it): Small coloured tabs or a bookmark ribbon poke out from the top of the spine, indicating the user has linked their own writing to this book.

---

### 1.4 Book Detail Page

#### US-1.4.1 Open a Book's Detail Page

**As a** user, **I want to** click on a book spine to see its full details **so that** I can learn more about a book and manage it within my collection.

**What the user wants to accomplish:** Access all enriched data about a specific book — metadata, reviews, prices, author info, and personal notes.

**How they accomplish it:**
1. The user clicks on a book spine on any shelf (or in the Reading Pile), or on a book result from search, a blog post's book association, or any other surface where a book spine or title appears.
2. The book "slides out" from the shelf — an animation where the spine tilts forward and the full cover is revealed, expanding into a detail overlay.
3. The detail overlay loads on top of the current page with all enriched sections.
4. The underlying page remains visible as a blurred background behind the overlay, preserving the user's spatial context.
5. The user dismisses the overlay by clicking the X button, clicking outside the overlay area, or pressing Escape. The shelf or page behind is exactly as they left it.
6. The browser URL does not change — the overlay is a UI state, not a route. This ensures the back button returns the user to the previous page, not to the shelf behind the overlay.

**What they see on the page:**
The detail overlay has a parchment-toned background with the shelf's wallpaper visible as a blurred border behind it. A subtle shadow separates the overlay from the background. An X button sits in the top-right corner. The layout is a single scrollable panel divided into clearly labelled sections:

- **Header:** Cover image (large, left-aligned), title in serif typeface, author name, ISBN, and format indicators (small icons for hardcover, softcover, Kindle, e-book, audiobook — filled icons for formats the user owns, outlined for others). An aggregate rating displayed as a single number with a subtle star, averaged across sources.

- **About:** The book's description/synopsis in a readable paragraph. Warm cream background, generous line spacing.

- **What People Think:** A sentiment overview panel. Each source (GoodReads, Reddit, Storygraph) gets a row showing:
  - The source name and icon
  - A one-sentence LLM-generated sentiment summary (e.g., "Readers on Reddit find this a masterful but slow-burning character study")
  - A sentiment indicator (warm colour scale from critical to glowing)
  - Direct links to the original threads and reviews — clicking opens them in a new tab
  - The platform does NOT host full reviews. The goal is community discovery: linking users OUT to where conversations are happening.

- **Where to Buy (ZAR):** A list of configured South African bookshops (Exclusive Books, Takealot, Bob's Books, Bargain Books, Clarke's Bookshop) with:
  - Current price in ZAR
  - A price trend sparkline (last 6 months) — a tiny, elegant line chart in muted gold
  - A direct link to buy
  - Prices sorted lowest-first by default

- **The Author:** Author name, a link to their website, and their RSS feed. The latest RSS post is shown as a small card (title, date, first sentence, link). Upcoming events or new releases are highlighted if available.

- **My Writing:** A section showing the user's own blog posts that the platform's LLM has associated with this book, plus any posts the user has manually linked. Displayed as a list of post titles, dates, and a one-line excerpt. An "Add post" button allows the user to manually associate a native blog post. External writing links are not supported here — a single website/blog URL lives on the user's profile.

- **Move to Shelf:** A dropdown styled as a wooden shelf label. The user can move the book to any shelf (Library, AntiLibrary, WishList, Reading Pile, Looking for a Home). The transition is recorded in the book's history.

- **Format Indicators:** A row of icons (hardcover, softcover, Kindle, e-book, audiobook). The user clicks to toggle which formats they own. Filled icon = owned, outlined = not owned. When multiple ISBNs are linked (see US-1.1.8), each format shows its own availability and pricing in the "Where to Buy" section.

- **Search-Surfaced Enrichment:** When the user's search query (US-1.5.3) matches external data — other users' public shelves, marketplace listings, partner inventory, or Third Spaces events related to this book — the relevant results are surfaced inline within the appropriate sections of the detail overlay. For example, a marketplace listing appears in a new "Available Second-Hand" section; partner inventory in the "Available Locally" section; related events in "The Author" section. This enrichment is contextual to the book, not a separate search results page.

---

### 1.5 Shelf Navigation & Search

#### US-1.5.1 Search Across Shelves

**As a** user, **I want to** search for a book across all my shelves **so that** I can quickly find any book in my collection regardless of which shelf it's on.

**What the user wants to accomplish:** Locate a specific book without having to browse each shelf individually.

**How they accomplish it:**
1. The user clicks the search icon in the top navigation bar (or presses a keyboard shortcut).
2. A search bar drops down, styled as a card catalogue drawer sliding open.
3. The user types a query (title, author, or keyword).
4. Results appear instantly as the user types — Elm has all book data in memory for a single user (typically hundreds of books), so local filtering is immediate.
5. Each result shows the book's spine thumbnail, title, author, and which shelf it's on.
6. Clicking a result opens the book detail overlay (US-1.4.1) on top of the current page.

**What they see on the page:**
- The search bar has a warm cream background with a serif placeholder: "Search your collection..."
- Results appear in a dropdown list below the search bar, grouped by shelf.
- A scope toggle allows searching "All shelves" or a specific shelf.
- Sorting options: title (A–Z), author (A–Z), date added (newest/oldest), rating (highest/lowest).
- Filter chips for genre, format, and price range appear below the search bar when results are shown.

---

#### US-1.5.2 Full-Text Search Across Reviews and Descriptions

**As a** user, **I want to** search across book descriptions and review summaries **so that** I can find books based on themes, topics, or sentiments mentioned in reviews.

**What the user wants to accomplish:** Discover books in their collection based on deeper content than just title and author.

**How they accomplish it:**
1. The user enters a query in the search bar and toggles the scope to "Deep search."
2. The system queries the backend API for full-text search across stored descriptions, review summaries, and subjects.
3. Results return with highlighted matching snippets.

**What they see on the page:**
- Results include a snippet of matching text with the search term highlighted in a warm amber.
- A subtle indicator distinguishes instant local results from API-fetched deep results (e.g., a small "via deep search" label).

---

#### US-1.5.3 Platform-Wide Discovery Search

**As a** user, **I want** my searches to surface results beyond my own collection **so that** I can discover books available from other users, local partners, and the wider platform without leaving the search flow.

**What the user wants to accomplish:** When searching for a book, see not just their own shelves but also marketplace listings, partner inventory, other users' public shelves, and related Third Spaces events — all in one place.

**How they accomplish it:**
1. The user types a query in the search bar (US-1.5.1).
2. Local results from the user's collection appear instantly (as before).
3. Concurrently, the system queries the backend for platform-wide matches: other users' public shelf placements, active marketplace listings, partner inventory, and Third Spaces events whose related ISBNs or descriptions match the query.
4. Platform-wide results appear in a separate section below the user's collection results, after a brief loading indicator.
5. Clicking any result opens the book detail overlay (US-1.4.1). External results that match a book the user already owns open that book's detail overlay enriched with the matched external data (e.g., a marketplace listing appears in the "Available Second-Hand" section). External results for books the user doesn't own open a lightweight detail overlay showing available metadata, with an "Add to my collection" action.

**What they see on the page:**
- The search dropdown is divided into two sections: "Your Collection" (instant local results) and "On the Platform" (API-fetched external results).
- External results show: book title, author, and a contextual label — "Listed by [username] for R120" (marketplace), "In stock at [partner name]" (partner inventory), "On [username]'s shelf" (public shelf), or "Event: [event name] at [venue]" (Third Spaces).
- External results load asynchronously — a subtle shimmer placeholder appears while fetching.
- Results respect visibility rules: only books on public shelves appear. Blocked users' content is filtered out.
- The scope toggle from US-1.5.1 gains a third option: "All shelves" / "[Specific shelf]" / "Whole platform".

---

### 1.6 The Reading Journey

#### US-1.6.1 Move a Book Between Shelves

**As a** user, **I want to** move a book from one shelf to another **so that** I can track my reading journey as a book progresses from wish to read.

**What the user wants to accomplish:** Record the natural journey of a book: WishList to AntiLibrary to Reading Pile to Library — and optionally onward to Looking for a Home when they're ready to part with it.

**How they accomplish it:**
1. On the book detail overlay, the user clicks the "Move to Shelf" dropdown.
2. They select the target shelf. All five bookshelves are available as targets from any source shelf: Library, AntiLibrary, WishList, Reading Pile, and Looking for a Home.
3. The book's spine animates off the current shelf (sliding out) and the system confirms the move.
4. Navigating to the target shelf reveals the book in its new position.
5. The transition is recorded in the book's history with a timestamp.
6. Books can also be moved *back* from Looking for a Home to any other shelf if the user changes their mind about parting with the book.

**What they see on the page:**
- The dropdown is styled as a set of small wooden shelf labels. All five shelves are listed.
- On selection, a brief confirmation: "Moved to Reading Pile" with a subtle animation of the book sliding to the right.
- The book's wear state updates to match the new shelf context over time.
- Moving to Looking for a Home shows a warm confirmation: "Ready to find a new home? We'll show this on the marketplace when you're ready to list it."
- Moving *back* from Looking for a Home shows: "Changed your mind? [Title] is back on your [Shelf Name]."

---

#### US-1.6.2 Abandon a Book Back to AntiLibrary

**As a** user, **I want to** move a book from the Reading Pile back to the AntiLibrary **so that** I can acknowledge I've stopped reading it without removing it from my collection.

**What the user wants to accomplish:** Gracefully abandon a book without judgement — it returns to the unread shelf.

**How they accomplish it:**
1. On the book detail overlay (while the book is in the Reading Pile), the user selects "AntiLibrary" from the Move to Shelf dropdown.
2. The system records the transition, including that it was an abandonment (moved backwards in the journey).

**What they see on the page:**
- The confirmation message is gentle: "Back to the AntiLibrary. No rush — it'll be here when you're ready."
- The book's spine wear remains at "cracking" for a period before gradually softening back to the AntiLibrary's "softened" state, visually preserving the reading attempt.

---

#### US-1.6.3 Record Multiple Reads

**As a** user, **I want** the system to track when I've read a book multiple times **so that** its spine wear reflects how well-loved it is.

**What the user wants to accomplish:** Have re-reads recorded and reflected in the book's visual presentation.

**How they accomplish it:**
1. A book already in the Library can be moved back to the Reading Pile and then returned to the Library.
2. Each round trip increments the read count.
3. The spine wear progresses from "well-read" to "well-loved" after multiple reads.

**What they see on the page:**
- On the book detail overlay, a small "Read 3 times" indicator appears below the title.
- The spine on the Library shelf shows increasingly heavy wear — deeper creases, more fading, more character.

---

#### US-1.6.4 Remove a Book from the Collection

**As a** user, **I want to** permanently remove a book from my collection **so that** I can correct mistakes or declutter shelves without affecting other data.

**What the user wants to accomplish:** Get rid of a book that was added by mistake, or that they no longer want to track. This is different from moving between shelves — this is removal.

**How they accomplish it:**
1. On the book detail overlay, the user clicks "Remove from collection" (in a less prominent position than shelf actions — this is intentionally not the primary action).
2. A confirmation modal appears explaining what will happen: "This will remove [Title] from your [Shelf Name]. Your shelf history and any linked writing will be preserved in your records but the book won't appear on any shelf."
3. The user confirms.
4. The book's shelf placement is soft-deleted (`removed_at` set). The book record itself remains in the database (other users or marketplace listings may reference it).
5. The history of the book's journey (shelf transitions) is preserved in `shelf_placement_history`.

**What they see on the page:**
- The confirmation modal has a warm amber background with a book icon being placed in a box.
- After confirmation, the book spine slides out of the shelf with a gentle fade.
- A toast notification: "[Title] has been removed from your collection. You can always add it again later."
- The book no longer appears on any shelf, in search results, or in shelf counts.

---

#### US-1.6.5 Empty Shelf States

**As a** user, **I want to** see an inviting empty state when a shelf has no books **so that** I feel encouraged to add books rather than confused by a blank screen.

**What the user wants to accomplish:** Understand that an empty shelf is normal (especially when they're just starting out) and know how to add their first book.

**How they accomplish it:**
This is automatic — no user action. The system renders an empty state when a shelf has zero active placements.

**What they see on the page:**
- **Library (empty):** The dark walnut shelf is visible but bare. A gentle message in serif typeface: "Your library is waiting. Move a book here when you've finished reading it." A subtle outline of a book spine suggests where books will appear.
- **AntiLibrary (empty):** The lighter oak shelf with a message: "Books you own but haven't read yet. Upload a photo to start building your collection." An "Add a Book" button is centred on the shelf.
- **WishList (empty):** Blue-grey shelf: "Books you're dreaming about. Add one from a photo, a screenshot, or an ISBN."
- **Reading Pile (empty):** The armchair is visible with an empty side table. A cup of tea sits alone. "Nothing on the pile right now. Move a book from your AntiLibrary to start reading."
- **Third Spaces (empty cork board):** A bare cork board with a single drawing pin and a message: "No spaces discovered yet. We'll find reading groups and cosy cafes near you, or you can suggest one." A "Pin a new space" button.
- **Metrics Dashboard (empty):** The curator's desk with a closed ledger: "Your metrics will appear here once the system starts processing books and enrichment data."

---

## 2. Enrichment & Discovery

### 2.1 Review Aggregation

#### US-2.1.1 View Aggregated Review Sentiments

**As a** user, **I want to** see a summary of what people think about a book across multiple platforms **so that** I can get a balanced sense of reception without reading hundreds of reviews.

**What the user wants to accomplish:** Quickly understand the sentiment around a book from GoodReads, Reddit, and Storygraph, with links to dive deeper.

**How they accomplish it:**
1. The user opens a book detail overlay.
2. The "What People Think" section is already populated with sentiment data.
3. The user reads the per-source summaries and clicks through to original threads.

**What they see on the page:**
- Each source (GoodReads, Reddit — including r/books, r/booksuggestions — Storygraph) has its own card.
- Each card shows: source icon, a one-sentence LLM-generated sentiment summary with citations, a colour-coded sentiment bar (deep red for critical, warm amber for mixed, deep green for glowing), and clickable links to the original review pages/threads.
- A small "Last refreshed: 3 days ago" timestamp at the bottom of the section.
- Books in the Reading Pile refresh more frequently; books in the Library refresh less often.

---

### 2.2 Price Tracking

#### US-2.2.1 View Prices Across Bookshops

**As a** user, **I want to** see current prices for a book across multiple South African bookshops **so that** I can find the best deal.

**What the user wants to accomplish:** Compare prices at Exclusive Books, Takealot, Bob's Books, Bargain Books, Clarke's Bookshop, and any other configured stores.

**How they accomplish it:**
1. The user opens a book detail overlay.
2. The "Where to Buy (ZAR)" section lists all configured stores with current prices.

**What they see on the page:**
- A vertically stacked list of bookshop cards, sorted by price (lowest first).
- Each card shows: store name/logo, current price in ZAR (bold serif type), a price trend sparkline covering the last 6 months (thin, muted gold line on a warm background), and a "Buy" link that opens the store page in a new tab.
- If a store doesn't stock the book, it shows "Not available" in grey italics.
- A note at the bottom: "Prices checked by The Stacks' scraping service. Last updated: [timestamp]."

---

#### US-2.2.2 Configure Bookshop Scrapers

**As a** user (self-hoster), **I want to** add or modify bookshop scrapers via TOML config files **so that** I can track prices from stores relevant to my country or region.

**What the user wants to accomplish:** Customise which bookshops are scraped without modifying application code.

**How they accomplish it:**
1. The user creates or edits a TOML configuration file in the designated scrapers directory.
2. Each file defines a store: name, base URL, search URL pattern, CSS selectors for price extraction, and currency.
3. The Rust scraping microservice reads these configs and begins scraping on the next scheduled run.

**What they see on the page:**
- After adding a new store config, the store appears in the "Where to Buy" section on book detail overlays once prices have been fetched.
- The Metrics Dashboard (see Section 6) shows the new source in its "Configured Sources" count.

---

### 2.3 Author Intelligence

#### US-2.3.1 View Author Information and Latest Activity

**As a** user, **I want to** see author details including their website, RSS feed, and upcoming events **so that** I can stay connected to authors I care about.

**What the user wants to accomplish:** Discover new content and events from favourite authors without leaving The Stacks.

**How they accomplish it:**
1. The user opens a book detail overlay.
2. The "The Author" section displays author information, auto-discovered by the system.

**Data provenance:** Author information is auto-discovered during book addition. When a book's ISBN is resolved via Open Library or Google Books, the system extracts the author's name, website URL (if available in metadata), and searches for their RSS feed and social presence using the Source Discovery Agent (Brave Search / SearXNG). The system stores a confidence score for each piece of discovered data. In the current phase, author data is system-managed — users cannot directly edit it. Users can submit corrections via a "Report an issue" link (see below), which flags the data for manual review by the platform owner.

**What they see on the page:**
- Author name in serif typeface.
- A link to their website (opens in new tab).
- The latest post from their RSS feed displayed as a small card: post title, publication date, the first sentence, and a "Read more" link.
- If upcoming events or new releases are known, they appear as highlighted notices: "New release: [Title], expected [Date]" or "Signing at [Venue], [Date]."
- A small "Report an issue" link below the author section, styled in muted text. Clicking opens a simple form: "What's wrong?" with options like "Wrong website", "Missing RSS feed", "Wrong author for this book", and a free-text field. Submissions are sent to the platform owner for review. No account creation or external service is required.
- A subtle "Auto-discovered" label indicates the data source. In future phases, this may evolve into a Wikipedia-style collaborative editing system.

---

### 2.4 Bookstore Events

#### US-2.4.1 Discover Relevant Bookstore Events

**As a** user, **I want to** be notified of bookstore events related to authors and books in my collection **so that** I can attend signings, readings, and launches in person.

**What the user wants to accomplish:** Find real-world literary events at physical bookstores that are relevant to their reading interests.

**How they accomplish it:**
1. The system scrapes bookstores with physical locations for upcoming events (signings, readings, launches, book clubs).
2. Events are matched against the user's collection — if the user owns books by the featured author, the event is surfaced.
3. Events appear on the book detail overlay (under "The Author") and on the Third Spaces page.

**What they see on the page:**
- A highlighted event card: "Exclusive Books Rosebank: Damon Galgut signing, March 15 — you own 2 of his books."
- The card includes date, time, venue, a brief description, and a link to the event page.
- Events are styled with a warm amber highlight to distinguish them from static information.

---

### 2.5 Source Discovery Agent

#### US-2.5.1 Automatic Discovery of New Sources

**As a** user, **I want** the system to automatically find new bookshops, review sites, and communities **so that** my enrichment data stays fresh and comprehensive without manual configuration.

**What the user wants to accomplish:** Have the system proactively expand its source network by discovering new places to find prices, reviews, and literary communities.

**How they accomplish it:**
1. When a new book is added, the Source Discovery Agent is triggered automatically (not user-initiated) to find sources relevant to that specific book.
2. The agent uses the Brave Search API (primary) and self-hosted SearXNG (fallback) to search for new sources.
3. An LLM evaluates each discovered source, assigning a confidence score based on relevance, reliability, and content quality.
4. High-confidence suggestions are queued for user approval.
5. Periodic broad sweeps (quarterly) search for entirely new source types.
6. **Geographic discovery sweep:** When the user first sets their location (US-17.2.2), and periodically thereafter (quarterly), the agent runs a location-based sweep searching for bookshops, reading groups, cafes, and literary communities in the user's configured city and country. This populates the Third Spaces page independently of any book-specific trigger. See US-2.5.2 for details.

**What they see on the page:**
- A notification badge appears on the Metrics Dashboard or in the top navigation: "3 new sources discovered."
- Clicking through shows a list of suggested sources, each with: source name, URL, type (bookshop, review site, community), confidence score, and a sample of what was found.
- The user can "Approve" (adds the source to TOML scraper configs) or "Dismiss" each suggestion.
- Approved sources begin appearing in enrichment data on subsequent scraping runs.

---

#### US-2.5.2 Geographic Discovery Sweep

**As a** user, **I want** the system to discover bookshops, reading groups, and literary spaces in my area based on my location **so that** my Third Spaces page is populated with relevant local results even before I add books.

**What the user wants to accomplish:** Have the Third Spaces cork board (US-3.1) populated with local discoveries based on where they live, not only based on which books they own.

**How they accomplish it:**
1. The user sets their location in their profile (US-17.2.2).
2. The system immediately triggers a geographic discovery sweep for the configured city and country.
3. The agent searches for: "bookshop {city}", "reading group {city}", "book club {city}", "literary festival {city}", "book cafe {city}", and similar queries using Brave Search and SearXNG.
4. Discovered spaces and events are evaluated by the LLM and queued for the platform owner's approval (or auto-approved if the owner has configured auto-approval for geographic discoveries).
5. The sweep repeats quarterly to capture new openings, events, and seasonal changes.
6. Results from the geographic sweep merge with results from book-specific source discovery (US-2.5.1) on the Third Spaces page.

**What they see on the page:**
- After setting their location, a subtle message on the Third Spaces page: "Discovering spaces near [City]..." with a gentle loading state.
- Within minutes to hours (depending on approval flow), discovered spaces begin appearing on the cork board.
- Each card indicates its source: "Discovered via local search" for geographic sweep results vs. "Related to [Book Title]" for book-triggered results.

---

#### US-2.5.3 Business Opt-Out from Platform Listings

**As a** business owner whose venue or shop has been discovered and listed on a Stacks instance, **I want to** request removal of my listing **so that** I have control over whether my business appears on the platform.

**What the business wants to accomplish:** Exercise their right to not be listed on a platform they didn't opt into, while being aware of the opportunity to become a verified partner instead.

**How they accomplish it:**
1. Every discovered (non-partner) listing on the Third Spaces page and in "Where to Buy" sections includes a small, discreet link at the bottom of the card: "Is this your business?"
2. Clicking the link opens a simple form: business name, contact email, and a choice between "Remove my listing" and "I'd like to become a partner instead."
3. For removal requests: the platform owner is notified and the listing is taken down promptly. The business's URL is added to an exclusion list so future discovery sweeps do not re-add it.
4. For partnership interest: the request is routed to the partner onboarding flow (US-9.1.1) with the business details pre-filled.

**What they see on the page:**
- The "Is this your business?" link is styled subtly — small text, muted colour, positioned below the card content. It does not detract from the reader experience.
- The form is simple and does not require account creation. A confirmation email is sent to verify the request.
- After removal, the listing disappears from all reader-facing pages within 24 hours.

**What the platform owner sees:**
- Removal requests appear in the Metrics Dashboard alongside partner requests, styled as a distinct card type: "Removal request from [Business Name]."
- The owner can process the removal with one click. A log entry is created in the audit trail.

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

## 4. Content Moderation

#### US-4.1 Three-Step Content Moderation Pipeline

**As a** user, **I want** every uploaded image to go through a rigorous moderation pipeline **so that** only legitimate book content enters the platform and sensitive material is appropriately gated.

**What the user wants to accomplish:** Trust that the platform will never display inappropriate non-book content and that sensitive book topics are handled responsibly.

**How they accomplish it:**
The moderation pipeline runs automatically on every upload:

1. **Step 1 — Image Classification:** The vision model checks whether the image is a photo of or about a book. If not, the image is rejected immediately (see US-1.1.3). Nudes, pets, food, and other non-book images are caught here.
2. **Step 2 — Text Extraction & ISBN Resolution:** The vision model extracts text and the system attempts to resolve an ISBN. If no ISBN is found, the book is rejected (see US-1.1.2).
3. **Step 3 — Subject Moderation:** The book's metadata subjects and categories are checked against a sensitive content list (BISAC codes, Open Library subjects). If flagged (anatomy, sexuality, etc.), the book is marked as age-gated.

**What they see on the page:**
- For rejected images: a clear, specific rejection message explaining which step failed and why.
- For age-gated books: the book is added but with a frosted overlay on the spine and a lock icon. The detail overlay requires age verification to access.
- The pipeline is invisible when everything passes — the user simply sees their book appear on the shelf.

---

#### US-4.2 Age Verification for Gated Content

**As a** user, **I want to** verify my age to access age-gated books **so that** I can view all content in my collection while the platform maintains responsible access controls.

**What the user wants to accomplish:** Complete age verification once and then freely access all age-gated content.

**How they accomplish it:**
- **Single-user phase (self-hosted):** The user sets their age in preferences. The system trusts this self-declaration.
- **Multi-user phase:** Integration with a KYC provider (Smile Identity, Yoti, or Sumsub) for proper age verification. The process verifies the user is 18+ without storing identity documents — only an `age_verified` boolean is retained.

**What they see on the page:**
- On first access to age-gated content, a verification prompt appears.
- Single-user: a simple "I confirm I am 18+" checkbox in settings.
- Multi-user: a flow that redirects to the KYC provider, completes verification, and returns. The page then displays: "Age verified. You now have full access."
- After verification, age-gated books display normally — the frosted overlay and lock icon are removed.

---

## 5. Metrics Dashboard (Operational Transparency)

#### US-5.1 View the Metrics Dashboard

**As a** user, **I want to** view a transparent operational dashboard **so that** I can see exactly how The Stacks is running, what it costs, and whether all systems are healthy.

**What the user wants to accomplish:** Have full visibility into the platform's operational state — not hidden behind an admin panel, but presented as part of the platform's aesthetic.

**How they accomplish it:**
1. The user clicks "Metrics" in the top navigation (or a subtle link in the footer).
2. The Metrics Dashboard loads — a custom Elm page, not Grafana.

**What they see on the page:**
- **Aesthetic:** A curator's desk. Warm wood surface, paper textures, scattered documents, a magnifying glass motif. Serif typography throughout. Muted gold sparklines on cream card backgrounds. The feeling of looking at a well-kept ledger.
- **System Health:** Uptime percentage (displayed as an elegant gauge), API latency (sparkline), database size, last deploy info (version, date, commit hash).
- **Jobs:** A table of background jobs — running, queued, failed. Columns: job name, status (colour-coded), last run, next scheduled run. Failed jobs are highlighted in a muted red.
- **Data Freshness:** A set of gauges showing what percentage of prices, reviews, author info, events, and third spaces data is within its SLA (e.g., "92% of prices updated within 7 days"). Each gauge has a colour: green for within SLA, amber for approaching, red for stale.
- **Source Discovery:** Count of configured sources, sources pending user review, Brave Search API and SearXNG usage (calls this month, remaining quota).
- **Costs:** An itemised monthly cost breakdown with data pulled from billing APIs:
  - Fly.io hosting
  - Vision API (Modal) calls and cost
  - Brave Search API usage
  - Domain registration
  - Total monthly cost
  - Cost per book (total cost divided by number of books in collection)
  - Each line item is displayed as a row in a ledger-style table with a running total.
- **Data Quality** (see `docs/data-quality.md`): Quality profiles per data product, not just pass/fail gauges:
  - **Quality Trends:** Sparkline per enrichment category (prices, reviews, author, events) showing 12-week freshness/completeness trend — is quality improving or degrading?
  - **Source Health:** A table of external data sources (scraper configs, review sites, RSS feeds) with per-source status: name, type, last successful fetch, consecutive failures, status (green = healthy, amber = degraded, red = broken). Broken sources are highlighted.
  - **Enrichment Gaps:** Counts of books/authors with missing data: "47 books with no prices", "12 authors with no RSS feed". Clickable to drill into the affected list. Gaps are grouped by cause (no scraper config, config broken, source doesn't stock it, never scraped).
  - **LLM Faithfulness:** Review summary spot-check agreement rate, blog association confirm/dismiss ratio, confidence distributions. A subtle indicator of whether AI-generated content is trustworthy.
- **GDPR & Data:** Images pending deletion (those past the 30-day retention window), audit log entry count, encryption status, data export availability.
- **Philosophy:** A note at the bottom in italic serif: "Every number here is real, unfiltered, and automated. If The Stacks ever becomes a paid service, you'll see exactly what it costs to run."

---

## 6. RSS Feeds

#### US-6.1 Subscribe to Shelf RSS Feeds

**As a** user (or a friend of the user), **I want** each public shelf to have an Atom feed **so that** I can follow what someone is reading and discover books through their collection.

**What the user wants to accomplish:** Share their reading activity passively via RSS, enabling friends to see updates without requiring accounts or social media.

**How they accomplish it:**
1. Each public shelf (Library, AntiLibrary, WishList, Reading Pile) automatically generates an Atom feed.
2. The feed URL is accessible from the shelf page — a small RSS icon in the shelf header.
3. Friends subscribe using any RSS reader.

**What they see on the page:**
- A small, tasteful RSS icon (styled to match the brass/wood aesthetic) in the top-right corner of each shelf page.
- Clicking it reveals the feed URL and a brief explanation: "Subscribe to this shelf in your RSS reader. You'll see when books are added, moved, or completed."
- Feed entries look like: "Erin moved The Secret History to Library" or "Erin added Piranesi to the Reading Pile" — each with the book title, author, cover thumbnail, and timestamp.
- This supports the community-first, physical-books ethos: if a friend sees you have a book, they might ask to borrow it in person.

---

## 7. Marketplace — "Looking for a New Home" (Future)

#### US-7.1 List a Book for Sale

**As a** user, **I want to** list a book I no longer want for second-hand sale **so that** it can find a new home with another reader.

**What the user wants to accomplish:** Sell a physical book from their collection to another reader in South Africa, with proper condition documentation and fair pricing.

**How they accomplish it:**
1. From any shelf, the user moves a book to the "Looking for a Home" shelf via the Move to Shelf dropdown on the book detail overlay.
2. A listing flow begins:
   - The user uploads 1–3 photos of the actual physical copy (showing condition — cover, spine, any damage).
   - The user selects a condition grade: New, Good, Fair, or Poor.
   - The user chooses a pricing model: fixed price (entered in ZAR) or open to offers (with an optional minimum price, or fully seller-declinable). (Closed bid is deferred to a future phase.)
3. The listing is published. Open and fixed-price listings are visible to all platform users by default.

**What they see on the page:**
- The "Looking for a New Home" shelf has its own distinct aesthetic (to be designed — perhaps a window ledge with books propped up, or a market stall).
- The listing form is warm and inviting: "Find this book a new home."
- Photo upload area for condition evidence (similar to the book upload flow).
- Condition selector styled as four book icons with increasing wear.
- Pricing section: a toggle between "Fixed Price" (with a ZAR input field) and "Open to Offers" (with an optional minimum field).
- After listing, the book appears on the marketplace shelf with its condition photos and price.

---

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
1. When payment is confirmed, the book is removed from the seller's "Looking for a Home" shelf. The listing is marked as "Sold" and no longer appears in marketplace search results.
2. The buyer receives a confirmation email (if notifications are enabled) and a prompt within the platform: "You've purchased [Title] by [Author]. Would you like to add it to one of your shelves?"
3. If the book was already on the buyer's WishList, the system detects this and offers: "This book is on your WishList. Move it to your Library or AntiLibrary?" The WishList placement is updated rather than duplicated.
4. If the book is not in the buyer's collection, they are prompted with a shelf picker (defaulting to AntiLibrary). Adding it is optional — the buyer may choose to dismiss the prompt.
5. The seller's placement history records the sale event: "Sold via marketplace on [date]" alongside the standard shelf transition history.

**What the buyer sees after purchase:**
- A warm confirmation card: "It's on its way! [Title] has found a new home." with estimated delivery date.
- Below the confirmation: "Add to your shelves?" with a shelf picker. If the book is on their WishList: "This was on your WishList! Move it to…" with Library and AntiLibrary as prominent options.
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

## 8. GDPR & Privacy

#### US-8.1 Export Personal Data

**As a** user, **I want to** export all my personal data **so that** I can exercise my right to access and portability under GDPR.

**What the user wants to accomplish:** Download a complete copy of all data The Stacks holds about them.

**How they accomplish it:**
1. The user navigates to Settings and clicks "Export My Data."
2. The system compiles all personal data: shelf contents, reading history, linked writing, preferences, audit logs.
3. The export is available as JSON and CSV. Potentially also OPDS format for book data portability.
4. A download link is provided.

**What they see on the page:**
- A settings section titled "Your Data" with a warm, reassuring tone.
- "Export My Data" button. On click: "Preparing your export..." with a progress indicator.
- When ready: download links for JSON, CSV, and (if supported) OPDS formats.
- A description of what's included in each format.

---

#### US-8.2 Delete All Personal Data

**As a** user, **I want to** delete all my personal data **so that** I can exercise my right to erasure under GDPR.

**What the user wants to accomplish:** Completely remove their presence from The Stacks, with proper cascade deletion and warehouse anonymisation.

**How they accomplish it:**
1. The user navigates to Settings and clicks "Delete My Data."
2. A confirmation dialog explains exactly what will be deleted and what will be anonymised.
3. The user confirms with a typed confirmation (e.g., typing "DELETE" to proceed).
4. The system performs a cascade delete: all personal data, shelves, reading history, linked writing, and preferences are removed. Analytics data is anonymised in the warehouse.

**What they see on the page:**
- A serious but respectful dialog: "This will permanently delete all your data from The Stacks. Analytics data will be anonymised. This cannot be undone."
- A text input requiring the user to type "DELETE" to confirm.
- After deletion: a farewell page confirming the action is complete, with no remaining session or data.

---

#### US-8.3 Consent Management

**As a** user, **I want to** manage my consent preferences with clear timestamps **so that** I know exactly what I've agreed to and when.

**What the user wants to accomplish:** Have full control and visibility over what data processing they've consented to.

**How they accomplish it:**
1. The user navigates to Settings > Privacy & Consent.
2. They see a list of consent items, each with a toggle and a timestamp of when it was last changed.

**What they see on the page:**
- A clean list of consent items: data collection, review aggregation, price scraping, image processing, analytics.
- Each item has: a clear description of what it covers, a toggle (on/off), and a timestamp ("Consented: 2026-01-15 14:32 UTC").
- Changes are logged in the audit trail immediately.

---

#### US-8.4 Image Retention Policy

**As a** user, **I want** my uploaded book photos to be automatically deleted after 30 days **so that** unnecessary personal data is not retained.

**What the user wants to accomplish:** Trust that uploaded images are ephemeral — used for identification and then disposed of.

**How they accomplish it:**
This is automatic. No user action required.
1. When a book is added via photo upload, the original images are stored temporarily.
2. Thumbnails are generated and kept for display purposes.
3. After 30 days, the original full-resolution images are permanently deleted.
4. Only thumbnails remain.

**What they see on the page:**
- On the Metrics Dashboard, the GDPR & Data section shows "Images pending deletion: [count]" — the number of images that haven't yet reached their 30-day expiry.
- In Settings > Privacy, a note: "Uploaded photos are deleted after 30 days. Only thumbnails are kept."

---

#### US-8.5 Audit Log

**As a** user, **I want to** view an audit log of all data access events **so that** I have full transparency into how my data has been used.

**What the user wants to accomplish:** Verify that their data is only being accessed for legitimate purposes.

**How they accomplish it:**
1. The user navigates to Settings > Audit Log.
2. A chronological list of data access events is displayed.

**What they see on the page:**
- A ledger-style table with columns: timestamp, event type (data export, review fetch, price scrape, admin access, etc.), data category affected, and a brief description.
- Data classification tiers are indicated: public book metadata, personal shelf data, sensitive KYC/payment data, external personal data (e.g., Reddit usernames referenced in reviews).
- External personal data (such as Reddit usernames encountered during review aggregation) is shown as pseudonymised in analytics contexts.
- The log is paginated and searchable.

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

**What the partner wants to accomplish:** Surface their available books alongside the user's shelves and search results, so that when a user is looking at a book, they can see "Available at [Shop Name] for R149".

**How they accomplish it:**
1. The partner sends a JSON payload to `POST /api/partner/inventory` containing a list of books, each identified by ISBN, with price, currency, condition (new/used), and quantity.
2. The payload is validated against the Protobuf-generated JSON schema: ISBN must be valid, price must be positive, condition must be from the enum.
3. Books with ISBNs already in the platform are linked immediately. Books with unknown ISBNs are queued for the standard ISBN resolution pipeline (Open Library / Google Books lookup).
4. The partner can send full snapshots or incremental updates (with an `action` field: `upsert` or `remove`).
5. All inventory data is surfaced only after the platform owner's initial approval of the partner. Subsequent inventory updates go live automatically unless the owner has enabled manual review for that partner.

**What the user sees:**
- On any book detail view, a "Available nearby" section on the cork-board sidebar shows partner shops that stock this book: shop name, price, condition, and a link to the shop's location or website.
- Availability is indicated with a small green dot on the book spine when browsing shelves (subtle, not intrusive).

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
3. Partners are sorted by proximity if the reader has set a location preference (US-4.x), otherwise alphabetically.
4. If no partners carry the book, the section doesn't appear (no empty state — the absence is silent).

**What they see on the page:**
- A subtle divider with "Available at" in the same serif font as shelf labels.
- Partner cards styled as small index cards: partner logo (or placeholder initial), name, price in local currency, book condition as a discrete badge (New, Like New, Good, Acceptable).
- On the bookshelf view: books with local availability show a small green dot on the spine's bottom edge — unobtrusive but discoverable.

---

---

## 10. Visibility & Privacy

### 10.1 Profile Visibility

#### US-10.1.1 Set Profile Visibility

**As a** user, **I want to** control who can see my profile **so that** I can choose whether to be discoverable on the platform or remain completely private.

**How they accomplish it:**
1. The user navigates to Profile Settings → Privacy.
2. They choose a profile visibility level:
   - **Owner only** — the profile is completely invisible to all other users. No one can find, follow, or see any trace of this account. Effectively a ghost mode.
   - **Platform users** — any logged-in user can find the profile and see whichever shelves, posts, and placements are set to platform-level visibility.
3. The change takes effect immediately.

**What they see on the page:**
- A privacy settings panel with a clear two-option toggle: "Private (only me)" and "Discoverable (platform members)".
- Ghost mode is explained plainly: "Your profile won't appear in search results or anyone's suggested readers. You can still browse the platform normally."
- A note that the `looking_for_home` shelf defaults to "Platform users" visibility — but only when the profile itself is set to "Platform users". If the profile is set to "Owner only", the ceiling applies and `looking_for_home` is also owner only. The user can make `looking_for_home` more restrictive than the profile default at any time via shelf settings.

**Ceiling rule:** all shelves, placements, and blog posts are subject to the profile visibility ceiling — content cannot be more visible than the profile that contains it. The `looking_for_home` shelf is not exempt from this rule; it simply has a different *default* visibility that activates when the profile is discoverable.

---

#### US-10.1.2 Block a User

**As a** user, **I want to** block another user **so that** they cannot see my profile, content, or interact with me anywhere on the platform.

**How they accomplish it:**
1. From any profile page, listing, comment, or Q&A, the user selects "Block [name]" from the overflow menu.
2. The system confirms: "Block [name]? They won't be able to see your profile or content, and you won't see theirs."
3. The user confirms.

**Effects of blocking:**
- The blocked user's profile becomes invisible to the blocker, and vice versa.
- In shared spaces (blog comments, marketplace Q&A), neither party can see the other's contributions. Sub-threads rooted in a blocked user's comment collapse entirely rather than showing a `[hidden]` placeholder.
- The block is not notified to the blocked user — they simply cannot find the blocker.

**What they see on the page:**
- A confirmation modal in the platform's dark-parchment style: "You've blocked [name]. You can undo this any time in Privacy Settings."
- A blocked users list in Privacy Settings where blocks can be reviewed and removed.

---

### 10.2 Content Visibility

#### US-10.2.1 Set Shelf Visibility

**As a** user, **I want to** control who can see each of my shelves **so that** I can share some reading lists while keeping others private.

**How they accomplish it:**
1. On any shelf page, the user opens the shelf settings menu (gear icon on the shelf header).
2. They choose a visibility level:
   - **Only me** — shelf is not visible to anyone else (default for all shelves except `looking_for_home`).
   - **Platform users** — any logged-in user can see the shelf and its contents.
   - **Group** — visible only to members of a specific group the user owns or belongs to.
   - **Specific people** — visible only to a named list of users.
3. The shelf's visibility is bounded by the profile ceiling. If the profile is set to "Only me", shelf-level settings have no effect.

**Age-gating note:** age-gated books (US-1.1.4) always require age verification before their detail overlays are accessible — regardless of the shelf's visibility level. Shelf visibility controls *discoverability*; age verification controls *access to content*. These are independent gates and apply equally to marketplace listings, partner availability data, and review aggregation for age-gated titles.

**What they see on the page:**
- A shelf settings drawer slides in from the right. The visibility section is labelled "Who can see this shelf?"
- A segmented control: Only me / Platform / Group / Specific people.
- Selecting Group shows a dropdown of the user's groups. Selecting Specific people shows a user search field where names can be added.
- The current visibility is shown as a small icon on the shelf header (a padlock, a globe, a group silhouette, or a person icon).

---

#### US-10.2.2 Override Placement Visibility

**As a** user, **I want to** make an individual book on a shelf less visible than the shelf itself **so that** I can hide specific books from people who can otherwise see the shelf.

**What the user wants to accomplish:** The shelf is visible to close friends, but one book on it is too personal to share — hide just that book without hiding the whole shelf.

**How they accomplish it:**
1. On any book spine or detail overlay, the user opens the book's context menu and selects "Visibility for this copy".
2. They choose a visibility level that is equal to or more restrictive than the shelf's current setting.
3. The book remains on the shelf but is hidden from anyone outside the chosen visibility level.

**Ceiling rule:** a placement cannot be made *more* visible than its shelf. The options shown are always a subset of or equal to the shelf's current visibility.

**What they see on the page:**
- The context menu item "Visibility for this copy" shows the current setting with a small icon.
- A modal with the same visibility options as shelf settings, but greyed-out options that would exceed the shelf's ceiling, with a tooltip: "This shelf is set to [level] — placements can't be more visible than their shelf."
- On the shelf view, hidden books show as a faint outline spine to the owner only — a visual reminder that something is there but not shown to others.

---

#### US-10.2.3 Set Blog Post Visibility

**As a** user, **I want to** control who can read each of my blog posts **so that** I can publish some posts widely and keep others within a trusted group.

**How they accomplish it:**
1. When writing or editing a post, the user sets the visibility before publishing (or can change it at any time).
2. Visibility options: Only me / Platform users / Group / Specific people — subject to the profile visibility ceiling.
3. A post set to "Only me" is saved as a draft-like private post. It does not appear in the user's public blog listing.

**What they see on the page:**
- The post editor has a visibility selector in the publish bar at the bottom, styled as a small dropdown with an icon.
- Unpublished/private posts appear in the user's own blog view with a padlock icon on the post card. They are invisible to everyone else.

---

### 10.3 View As

#### US-10.3.1 Preview Content Visibility

**As a** user, **I want to** preview how my profile and content appear to different audiences **so that** I can verify my visibility settings are correct before assuming they work.

**What the user wants to accomplish:** "I set my shelf to close-friends only — I want to confirm my mum can't see it even though my profile is discoverable."

**How they accomplish it:**
1. From Profile Settings → Privacy, the user clicks "Preview as…"
2. They choose a viewing perspective:
   - **Not logged in** — simulates an unauthenticated visitor. Confirms no content is visible to scrapers or non-members.
   - **Anyone on the platform** — simulates a logged-in stranger with no relationship to the user.
   - **Specific user** — the user types a name and previews exactly what that person would see (respecting blocks, group memberships, and individual grants).
   - **Group member** — the user selects one of their groups and previews as a generic member of that group.
3. The platform renders a read-only view of the profile as that audience would see it. A persistent banner reads "Previewing as [perspective] — this is not your live view."
4. The user can navigate shelves, posts, and placements within the preview. Clicking "Exit preview" returns to their normal view.

**What they see on the page:**
- The preview banner is styled in muted amber — unobtrusive but clearly visible. It shows the current perspective and an "Exit preview" button.
- All edit controls and navigation menus are hidden in preview mode.
- If "Not logged in" is selected and any content is visible, a warning badge appears: "Some content may be visible to unauthenticated visitors — review your settings."

---

### 10.4 Search Engine Privacy

#### US-10.4.1 Search Engine Privacy

**As a** user, **I want to** know that my profile and reading history will never appear in search engine results **so that** my presence on the platform remains private from the wider internet.

**How they accomplish it:** No action required — this is a platform-wide guarantee enforced automatically.

**What the platform does:**
- All user-generated pages include `<meta name="robots" content="noindex, nofollow">`.
- `robots.txt` disallows all crawlers from user profile, shelf, and post URLs.
- Unauthenticated requests to any user-data endpoint return no personal data — they receive either a redirect to the login page or an empty response.

**What they see:**
- In Privacy Settings, a single line: "Your profile and content will never appear in search engine results. This applies to all users and cannot be changed."

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
3. Feed items include: blog posts published with visibility set to this group (or broader), and shelf activity (books added, moved, or completed) from members whose shelves are visible to the group.

**What they see on the page:**
- The group page header shows: group name, type badge (close friends / broadcast / subscription), member count (for close friends groups), and an "Invite" button (for the owner).
- Below the header, a content feed styled as a stack of parchment cards:
  - **Blog posts** show: author display name, post title, first two lines, date, and a "Read" link that opens the full post.
  - **Shelf activity** shows: "[Name] added [Title] to their Reading Pile" or "[Name] moved [Title] to Library" — displayed as small, compact cards with the book spine thumbnail.
- For **broadcast** groups: only the owner's content appears (members are recipients, not contributors).
- For **close friends** groups: all members' content appears, creating a shared conversation.
- For **subscription** groups: the owner's content appears; members can see the feed but do not contribute to it.
- Content respects all visibility rules: a post set to "Only me" never appears, even in a close friends feed. A shelf set to "Only me" is excluded. The visibility ceiling (US-10.1.1) always applies.
- The feed does not use algorithmic ranking — it is strictly chronological. No infinite scroll; pagination at 20 items with a "Load more" link.

**Acceptance criteria:**
- [ ] Group pages display a reverse-chronological feed of member content
- [ ] Blog posts and shelf activity are included in the feed
- [ ] Content visibility rules are enforced per-item
- [ ] Broadcast groups show only the owner's content
- [ ] Close friends groups show all members' content
- [ ] Subscription groups show the owner's content
- [ ] Block filtering applies within group feeds

---

## 12. Blog

### 12.1 Writing

#### US-12.1.1 Write a Blog Post

**As a** user, **I want to** write and publish native blog posts on the platform **so that** I can share my thoughts on reading, books, and ideas with my audience.

**How they accomplish it:**
1. From their profile, the user navigates to "Writing" → "New Post".
2. They write in a minimal rich-text editor: title, body (with basic formatting — bold, italic, headings, blockquote, links).
3. They set visibility before publishing (see US-10.2.3).
4. They click "Publish". The post is timestamped and appears in their writing archive.

**What they see on the page:**
- The editor is clean and distraction-free: white or parchment background, serif typeface, no sidebar. Consistent with the platform's reading-first aesthetic.
- A word count appears subtly at the bottom.
- The publish bar at the bottom contains: visibility selector, a "Save draft" button, and a "Publish" button.
- Published posts appear on the user's profile under "Writing", displayed as a vertical list of cards — title, date, first two lines of body, and a visibility icon.

---

#### US-12.1.2 LLM Book Associations on a Post

**As a** user, **I want** the platform to surface connections between my writing and my reading history **so that** readers can explore the books that informed a post, and I can discover patterns in my own reading and thinking.

**What the platform does:**
1. After a post is published (or when the user requests it on a draft), an Oban job runs the post body through an LLM.
2. The LLM is given the post content and the user's full book catalogue (title, author, description, subjects).
3. It returns a ranked list of books from the catalogue that relate to the post, with a one-sentence reasoning for each association.
4. Associations are stored in `post_book_associations` with a confidence score. The top three are surfaced on the post by default.
5. The user can review, accept, dismiss, or manually add associations.

**What they see on the page:**
- Below each published post: a "Books from my shelves" section showing up to three book spines (small, inline) with the association reasoning as a tooltip on hover.
- An edit panel where the user can see all suggested associations, toggle them on/off, and manually link additional books from their collection.
- A subtle "Suggested by AI — you can edit these" label below the section.

---

#### US-12.1.3 Browse Another User's Blog

**As a** platform user, **I want to** read another user's blog posts **so that** I can follow their reading life and thinking.

**How they accomplish it:**
1. From a public profile, the user navigates to the "Writing" tab.
2. They see a list of posts scoped to their visibility level (only posts the author has made visible to this viewer).
3. They click a post to read it in full.

**What they see on the page:**
- The writing tab shows post cards: title, date, opening lines, and a read-time estimate.
- The post page is clean and typographic — the author's name and date at the top, the body in a readable serif, and the book associations section at the bottom.
- No algorithmic recommendations or infinite scroll. The archive is a simple reverse-chronological list.

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

---

## 14. Authentication & Account

### 14.1 Registration

#### US-14.1.1 Register a New Account

**As a** new user, **I want to** create an account on The Stacks **so that** I can start building my personal book collection.

**What the user wants to accomplish:** Set up their identity on the platform so they can begin adding books, organising shelves, and accessing all features that require authentication.

**How they accomplish it:**
1. The user navigates to The Stacks and clicks "Sign In" in the top navigation.
2. The authentication page loads with two tabs: "Sign In" and "Register". The user clicks the "Register" tab.
3. The registration form appears with three fields: Display Name, Email, and Password.
4. The user enters their chosen display name (the name that will appear on their profile and in any shared spaces), their email address, and a password.
5. The user clicks "Create Account".
6. The system validates the input, creates the account, and returns a JWT token.
7. On success, the user is authenticated immediately and redirected to the home page. Their display name appears in the top navigation where "Sign In" previously was.

**What they see on the page:**
- The registration page has a warm parchment background consistent with the platform aesthetic. The heading reads "Create Account" in a serif typeface.
- Two tabs at the top of the form allow switching between "Sign In" and "Register" modes without a page reload.
- The Display Name field has a placeholder: "Your name". The Email field has a placeholder: "you@example.com". The Password field shows masked dots.
- While submitting, the button displays a small turning-page spinner and is disabled to prevent double submission.
- On error (e.g., email already in use), a warm-toned error message appears below the form fields: "Registration failed. Email may already be in use."
- On success for returning users, the page transitions to the AntiLibrary with the user's display name visible in the navigation.
- On success for first-time users, the onboarding flow begins (see US-14.1.2).

**Acceptance criteria:**
- [ ] Registration form collects display name, email, and password
- [ ] Switching between Sign In and Register tabs preserves entered email and password
- [ ] Successful registration returns a JWT and authenticates the user immediately
- [ ] First-time registration triggers the onboarding flow (US-14.1.2)
- [ ] Subsequent logins redirect to the AntiLibrary (`/antilibrary`)
- [ ] Duplicate email addresses produce a clear, non-technical error message
- [ ] The submit button is disabled during the API request to prevent double submission
- [ ] Rate limiting is applied to the registration endpoint to prevent abuse

**Technical note:** In the single-user (self-hosted) phase, the first user to register becomes the platform owner. No public registration beyond the owner is available until the multi-user phase.

---

#### US-14.1.2 First-Time Onboarding Flow

**As a** new user who has just registered, **I want** a brief guided introduction to adding my first book **so that** I understand how The Stacks works without feeling overwhelmed or lost.

**What the user wants to accomplish:** Get oriented on the platform and add their first book, experiencing the core upload-verify-shelve flow in a supported way.

**How they accomplish it:**
1. After successful registration (US-14.1.1), instead of redirecting to the AntiLibrary, the system launches a lightweight onboarding overlay.
2. The overlay is a single-path flow with 3 steps:
   - **Step 1 — Welcome:** "Welcome to The Stacks. Let's add your first book." A warm illustration of an empty bookshelf. A "Let's go" button proceeds. A "Skip" link dismisses the entire flow and redirects to the AntiLibrary.
   - **Step 2 — Upload:** The standard upload drop zone (US-1.1.1) appears inline within the overlay. The user uploads a photo or enters an ISBN. The verification step ("We think this is…") plays out as normal.
   - **Step 3 — Shelf placement:** The user chooses a shelf for their first book (defaulting to WishList). On confirmation, the book is created and the overlay shows a brief celebration: the book spine sliding into place with a soft thud.
3. After the final step, the user is redirected to the shelf they chose, where their first book is visible.

**What they see on the page:**
- The onboarding overlay has a warm parchment background with a subtle vignette. The aesthetic is cinematic — a slow zoom into an empty shelf that fills with the first book.
- Each step has a clear, single-sentence instruction. No walls of text. The tone is warm and encouraging: "Drop a photo of a book you love", "Is this the right one?", "Where should it live?"
- A progress indicator shows 3 dots at the top of the overlay.
- The "Skip" link is always visible but unobtrusive — no guilt framing.
- After the last step, a message: "Your collection has begun." Then the shelf loads behind the fading overlay.

**Acceptance criteria:**
- [ ] Onboarding launches after first registration only (not on subsequent logins)
- [ ] The flow is fully dismissable at any step via the "Skip" link
- [ ] Skipping redirects to `/antilibrary`
- [ ] Completing the flow places the first book on the chosen shelf and redirects there
- [ ] The onboarding state is stored (e.g., `onboarding_completed` flag) so it never re-triggers

---

### 14.2 Login

#### US-14.2.1 Sign In to an Existing Account

**As a** returning user, **I want to** sign in to my account **so that** I can access my book collection and all authenticated features.

**What the user wants to accomplish:** Authenticate with their existing credentials and resume using the platform where they left off.

**How they accomplish it:**
1. The user navigates to The Stacks. If not already authenticated, they click "Sign In" in the top navigation.
2. The authentication page loads with the "Sign In" tab active by default.
3. The user enters their email and password.
4. The user clicks "Sign In".
5. The system validates the credentials against the stored Argon2-hashed password.
6. On success, the system issues a JWT token (24h access, 7d refresh) and redirects the user to the AntiLibrary (`/antilibrary`).
7. The top navigation updates to show the user's display name in place of the "Sign In" link.

**What they see on the page:**
- The sign-in page has the same warm parchment background as the rest of the platform. The heading reads "Sign In" in serif typeface.
- Two input fields: Email ("you@example.com") and Password (masked).
- A "Sign In" button styled as a primary action in the platform's dark-academic palette.
- While submitting, the button shows a small spinner and is disabled.
- On invalid credentials, a single error message appears: "Invalid email or password." The message is intentionally vague to prevent email enumeration.
- On success, a smooth transition to the AntiLibrary.

**Acceptance criteria:**
- [ ] Login form collects email and password
- [ ] Successful login returns a JWT and stores it for subsequent API requests
- [ ] The user is redirected to the AntiLibrary (`/antilibrary`) after successful login
- [ ] Invalid credentials produce a generic error message (no email enumeration)
- [ ] The submit button is disabled during the API request
- [ ] Rate limiting is applied to the login endpoint to prevent brute-force attacks

---

### 14.3 Session Management

#### US-14.3.1 Authenticated Navigation State

**As an** authenticated user, **I want** the navigation to reflect my signed-in state **so that** I can confirm I am logged in and see my identity at a glance.

**What the user wants to accomplish:** Have persistent visual confirmation that they are authenticated, without needing to check a settings page.

**How they accomplish it:**
This is automatic. When the user is authenticated, the top navigation updates.

**What they see on the page:**
- When signed in, the "Sign In" link in the navigation is replaced by the user's display name, rendered in the same serif typeface as other navigation items.
- The display name is not clickable in the current phase (no profile page yet). It serves as a visual indicator of the authenticated session.
- All protected pages (bookshelves, upload, search, settings) are accessible. API requests include the JWT automatically.

**Acceptance criteria:**
- [ ] The navigation shows "Sign In" when unauthenticated and the user's display name when authenticated
- [ ] The auth token is included in all API requests to protected endpoints
- [ ] Protected pages function correctly when authenticated

---

#### US-14.3.2 Session Expiry and Token Refresh

**As a** user whose session has expired, **I want to** be gracefully returned to the sign-in page **so that** I can re-authenticate without losing context about where I was.

**What the user wants to accomplish:** Understand why an action failed (expired session) and recover quickly without confusion.

**How they accomplish it:**
1. The user's JWT access token expires after 24 hours.
2. If a refresh token is available and valid (within 7-day window), the system silently obtains a new access token without user intervention.
3. If both tokens have expired, the next API request returns a 401 Unauthorized response.
4. The frontend detects the 401 and redirects the user to the sign-in page.

**What they see on the page:**
- If the token refreshes silently, the user sees nothing — the experience is seamless.
- If the session has fully expired, the user is redirected to the sign-in page. No harsh error message — simply the sign-in form ready for credentials.
- After re-authentication, the user is returned to the home page.

**Acceptance criteria:**
- [ ] Access tokens expire after 24 hours
- [ ] Refresh tokens are valid for 7 days and can silently renew access tokens
- [ ] Expired sessions result in a redirect to the sign-in page, not an error screen
- [ ] Re-authentication redirects the user to the AntiLibrary

---

#### US-14.3.3 Log Out

**As an** authenticated user, **I want to** sign out of The Stacks **so that** my session is ended and my personal data is no longer accessible from this browser.

**What the user wants to accomplish:** End their session explicitly — especially important on shared or public devices, or when switching accounts.

**How they accomplish it:**
1. The user clicks their display name in the navigation bar, which reveals a dropdown menu.
2. The dropdown contains: "Settings" (navigates to the settings index page, US-17.1.1) and "Sign Out".
3. Clicking "Sign Out" clears the stored JWT from the browser, resets the Elm application state, and redirects to the sign-in page.

**What they see on the page:**
- The display name in the navigation becomes a clickable element. On click, a dropdown appears with two items: "Settings" and "Sign Out".
- "Settings" navigates to the settings index page (`/settings`).
- After signing out, the user sees the sign-in page. The navigation reverts to the unauthenticated state (only "Costs" and "Sign In" visible).
- No confirmation dialog — sign-out is immediate and reversible (they can just sign in again).

**Acceptance criteria:**
- [ ] The display name dropdown contains "Settings" and "Sign Out"
- [ ] "Settings" navigates to `/settings`
- [ ] Clicking "Sign Out" removes the JWT from localStorage via the `clearAuth` port
- [ ] The Elm model's `auth` field is set to `Nothing`, clearing all personal data from application state
- [ ] The user is redirected to the sign-in page after signing out
- [ ] After signing out, navigating to a protected page redirects to sign-in
- [ ] The sign-out action works in both normal and private browsing sessions

---

## 15. Home & Navigation

### 15.1 Home Page

#### US-15.1.1 View the Home Page

**As a** user, **I want to** see a welcoming landing page when I visit The Stacks **so that** I understand what the platform is and can navigate to my collection or add a book.

**What the user wants to accomplish:** Orient themselves on arrival and quickly reach their collection or sign in.

**How they accomplish it:**
1. The user navigates to the root URL of The Stacks instance.
2. **If authenticated:** The user is immediately redirected to the AntiLibrary (`/antilibrary`). The home page is not shown — authenticated users land directly in their collection.
3. **If unauthenticated:** The home page loads with the platform title, a subtitle, and primary action links.

**What they see on the page (unauthenticated only):**
- A centred layout with "The Stacks" as the main heading in the platform's serif typeface.
- A subtitle: "Your personal collection, beautifully organised." — warm, inviting, understated.
- A single primary action button: "Sign In" (navigates to the authentication page). A secondary link: "Learn more" or "What is this?" that scrolls to a brief, elegant explanation below.
- The overall aesthetic is restrained and elegant — no hero images, no marketing copy, no onboarding carousel. The page trusts the user to know what they want.
- The global navigation is visible at the top (with limited items for unauthenticated users), and the footer is visible at the bottom.

**Acceptance criteria:**
- [ ] The home page renders at the root URL for unauthenticated users
- [ ] Authenticated users visiting `/` are redirected to `/antilibrary`
- [ ] The page displays the platform title and subtitle
- [ ] "Sign In" navigates to the authentication page
- [ ] The page is only shown to unauthenticated users

---

### 15.2 Global Navigation

#### US-15.2.1 Navigate Between Sections via the Top Navigation Bar

**As a** user, **I want** a persistent top navigation bar **so that** I can move between my bookshelves, search, upload, and settings from any page.

**What the user wants to accomplish:** Access any section of the platform in one click, regardless of which page they are currently viewing.

**How they accomplish it:**
1. The top navigation bar is always visible, fixed at the top of every page.
2. The user clicks a navigation item to move to that section.

**What they see on the page:**
- A header bar containing the platform logo ("The Stacks", linking to the home page) and a horizontal navigation list.
- **Authenticated navigation items:** Library, AntiLibrary, WishList, Reading Pile, Looking for a Home, Search, Add Book (links to `/upload`).
- **Unauthenticated navigation items:** Costs (links to the public cost transparency page), Sign In.
- The currently active page's navigation item is visually highlighted with an active state (e.g., a subtle underline or brighter text).
- When authenticated, the user's display name appears as the rightmost item in the navigation. Clicking it reveals a dropdown with two items: "Settings" (links to `/settings`) and "Sign Out" (see US-14.3.3). When unauthenticated, "Sign In" appears instead, linking to the login page.
- The navigation uses the platform's serif typeface and dark-academic colour palette. Items are styled as clean text links within a warm header bar.

**Acceptance criteria:**
- [ ] The navigation bar appears on every page
- [ ] Authenticated users see the full navigation (bookshelves, search, add book, display name)
- [ ] Unauthenticated users see only Costs and Sign In
- [ ] All navigation items link to the correct routes
- [ ] The active page is visually indicated in the navigation
- [ ] The display name dropdown contains "Settings" and "Sign Out"
- [ ] The platform logo links to `/` (redirects to `/antilibrary` for authenticated users)

---

#### US-15.2.2 Swipe Navigation Between Bookshelves (Mobile)

**As a** mobile user, **I want to** swipe left or right to move between adjacent bookshelves **so that** browsing my collection feels fluid and tactile on a touch device.

**What the user wants to accomplish:** Navigate between bookshelves using the natural swipe gesture familiar from mobile interfaces, reinforcing the spatial metaphor of moving between rooms.

**How they accomplish it:**
1. On a bookshelf page (Library, Antilibrary, Wish List, Reading Pile, Looking for a Home), the user swipes left or right on the screen.
2. A left swipe navigates to the next bookshelf in the sequence. A right swipe navigates to the previous bookshelf.
3. The shelf order follows the navigation bar order: Library, Antilibrary, Wish List, Reading Pile, Looking for a Home.
4. Swiping past the first or last shelf in the sequence does nothing — there is no wraparound.

**What they see on the page:**
- The same shelf transition animations as clicking the navigation: horizontal slides for adjacent shelves, fade-through-darkness for room transitions (as defined in US-1.2.5).
- No visible swipe indicator or gesture hint — the interaction is discoverable but not prompted.

**Acceptance criteria:**
- [ ] Swipe left on a bookshelf navigates to the next shelf in sequence
- [ ] Swipe right navigates to the previous shelf in sequence
- [ ] Swiping at the boundaries (first or last shelf) produces no navigation
- [ ] Swipe navigation triggers the same transition animations as click navigation
- [ ] Swipe gestures are detected via JavaScript ports and communicated to the Elm runtime

---

### 15.3 Footer

#### US-15.3.1 View the Platform Footer

**As a** user, **I want** a simple footer on every page **so that** I can see basic platform information and know I have reached the bottom of the page content.

**What the user wants to accomplish:** Have a visual anchor at the bottom of the page that reinforces the platform identity without being distracting.

**How they accomplish it:**
This is automatic — the footer appears on every page.

**What they see on the page:**
- A footer bar at the bottom of the page with the text: "The Stacks — open source book management".
- The footer is styled in muted tones consistent with the platform aesthetic — understated, not attention-grabbing.
- The footer does not contain navigation links, social media icons, or legal boilerplate in this phase.

**Acceptance criteria:**
- [ ] The footer appears on every page
- [ ] The footer displays the platform tagline
- [ ] The footer is visually consistent with the platform aesthetic

---

## 16. Error States & Edge Cases

### 16.1 Page Not Found

#### US-16.1.1 View the 404 Not Found Page

**As a** user who has navigated to a URL that does not exist, **I want to** see a clear, friendly error page **so that** I understand the page was not found and can navigate back to a valid part of the platform.

**What the user wants to accomplish:** Recover from a broken link, a mistyped URL, or a stale bookmark without feeling lost or confused.

**How they accomplish it:**
1. The user navigates to any URL that does not match a known route (e.g., `/nonexistent-page`).
2. The Elm router cannot parse the URL and falls through to the `NotFound` route.
3. A dedicated not-found page is rendered.

**What they see on the page:**
- A page heading: "Page Not Found" — direct and unambiguous.
- A brief explanation: "The page you're looking for doesn't exist."
- A primary action button: "Go Home" linking back to the root URL.
- The page uses the same layout and aesthetic as the rest of the platform — navigation and footer are visible, so the user does not feel ejected from the application.
- The browser tab title reads "Not Found — The Stacks".

**Acceptance criteria:**
- [ ] Any unrecognised URL renders the not-found page instead of a blank screen or browser error
- [ ] The page displays a heading, explanation, and a link to the home page
- [ ] The global navigation and footer remain visible
- [ ] The browser tab title updates to "Not Found — The Stacks"

---

### 16.2 Network & API Errors

#### US-16.2.1 Handle Network Failures Gracefully

**As a** user whose network connection is unreliable, **I want** API failures to be communicated clearly **so that** I understand what went wrong and can retry when my connection is restored.

**What the user wants to accomplish:** Distinguish between a platform problem and a local connectivity issue, and know that their data is safe.

**How they accomplish it:**
This is automatic — the Elm frontend uses the `RemoteData` pattern for all API interactions, which explicitly models loading, success, and failure states.

**What they see on the page:**
- When an API request fails due to a network error, the affected section of the page displays an inline error message rather than crashing or going blank.
- Error messages are specific to the context: "Couldn't load your Library. Check your connection and try again." or "Upload failed. Please try again."
- On the login/registration form, API errors appear as form-level messages below the fields.
- No data is lost — form inputs are preserved, and the user can retry without re-entering information.
- The rest of the page remains functional. A failure in one section (e.g., loading a bookshelf) does not take down the entire application.

**Acceptance criteria:**
- [ ] All API-backed pages use RemoteData to model loading, success, and failure states
- [ ] Network failures display contextual inline error messages, not generic browser errors
- [ ] Form inputs are preserved when a submission fails
- [ ] Failures in one section do not affect the rest of the page
- [ ] The user can retry failed actions without refreshing the page

---

### 16.3 Authentication Errors

#### US-16.3.1 Handle Unauthenticated Access to Protected Pages

**As a** user who is not signed in, **I want** protected pages to redirect me to the sign-in page **so that** I can authenticate and then access the content I was trying to reach.

**What the user wants to accomplish:** Understand that the content they are trying to access requires authentication, and be guided to sign in rather than seeing a raw error.

**How they accomplish it:**
1. The user navigates directly to a protected URL (e.g., `/library`, `/upload`, `/settings/consent`) without being authenticated.
2. The API returns a 401 Unauthorized response.
3. The frontend redirects the user to the sign-in page.

**What they see on the page:**
- The sign-in page loads normally. No error banner or warning — the redirect itself communicates the need to authenticate.
- After signing in, the user is redirected to the AntiLibrary (`/antilibrary`).

**Acceptance criteria:**
- [ ] Unauthenticated API requests to protected endpoints return 401
- [ ] The frontend handles 401 responses by redirecting to the sign-in page
- [ ] The sign-in page loads cleanly after the redirect
- [ ] After authentication, the user is redirected to `/antilibrary`
- [ ] After authentication, the user is redirected to the home page

---

## 17. Settings & Preferences

### 17.1 Settings Hub

#### US-17.1.1 Settings Index Page

**As a** user, **I want** a central settings page that links to all my account, privacy, and profile settings **so that** I can find and manage everything about my account in one place.

**What the user wants to accomplish:** Discover and navigate to all settings sub-pages without memorising URLs or hunting through menus.

**How they accomplish it:**
1. The user clicks their display name in the top navigation bar and selects "Settings" from the dropdown (US-14.3.3).
2. The settings index page loads at `/settings`.

**What they see on the page:**
- A page titled "Settings" in the platform's serif typeface, on a warm parchment background.
- A left sidebar lists all settings categories as navigation links. The main content area displays the selected sub-page.
- Settings categories:
  - **Profile** (`/settings/profile`) — display name, email, location, and website/blog URL (US-17.2.1)
  - **Password** (`/settings/password`) — change password (US-17.2.3)
  - **Privacy & Consent** (`/settings/consent`) — consent toggles with timestamps (US-8.3)
  - **Age Verification** (`/settings/age-verification`) — self-declaration toggle (US-4.2)
  - **Data Export** (`/settings/export`) — export personal data (US-8.1)
  - **Delete Account** (`/settings/delete`) — right to erasure (US-8.2)
  - **Audit Log** (`/settings/audit`) — data access event log (US-8.5)
  - **Notifications** (`/settings/notifications`) — email notification preferences (US-17.3.1)
- The sidebar highlights the currently active sub-page. On mobile, the sidebar collapses to a dropdown selector.

**Acceptance criteria:**
- [ ] `/settings` renders the settings index page with sidebar navigation
- [ ] Clicking each sidebar link loads the corresponding sub-page
- [ ] The settings page is accessible from the display name dropdown in the top navigation
- [ ] All sub-pages are only accessible to authenticated users
- [ ] The sidebar highlights the active sub-page
- [ ] All sub-pages use the platform's parchment background and serif typography

---

### 17.2 Profile Management

#### US-17.2.1 View and Edit Profile

**As a** user, **I want to** manage my display name, email, and personal website **so that** my public identity on the platform is accurate.

**What the user wants to accomplish:** Update their basic account information — the name others see, their email for account recovery, and an optional link to their personal website or blog.

**How they accomplish it:**
1. The user navigates to Settings > Profile (`/settings/profile`).
2. They see their current display name, email, and website URL (if set).
3. They edit any field and click "Save".

**What they see on the page:**
- A simple form with three fields: Display Name, Email, and Website/Blog URL (optional).
- The display name field shows a preview: "This is how you appear to other users."
- The email field includes a note: "Used for account recovery and notifications. Not visible to other users."
- The website field is described: "A link to your personal blog or website. Shown on your public profile."
- A "Save" button. Changes take effect immediately. A subtle confirmation: "Profile updated."

**Acceptance criteria:**
- [ ] `/settings/profile` renders the profile editing form
- [ ] Display name changes are reflected in the navigation bar immediately
- [ ] Email changes require the current password for confirmation
- [ ] All fields validate before saving (email format, URL format)

---

#### US-17.2.2 Set Location

**As a** user, **I want to** set my city and country **so that** Third Spaces, partner inventory, and events are filtered to my area.

**What the user wants to accomplish:** Tell the platform where they are so that local content (bookshops, reading groups, events, cafes) is relevant. This is an explicit setting, not device-based geolocation.

**How they accomplish it:**
1. The user navigates to Settings > Profile (`/settings/profile`).
2. Below the basic profile fields, a "Location" section shows two fields: Country (dropdown) and City (text input with autocomplete).
3. The user selects their country and types their city.
4. On save, the system triggers a geographic discovery sweep (US-2.5.2) for the new location.

**What they see on the page:**
- A "Location" section with a brief explanation: "We use your location to show nearby bookshops, events, and reading spaces. We don't use device location — you set it here."
- Country is a dropdown (prepopulated with South Africa at the top, then alphabetical). City is a text input with autocomplete suggestions.
- After saving, a note: "We'll start looking for bookshops and reading spaces near [City]. Check Third Spaces soon."
- If the user changes their location, a new geographic sweep is triggered and old location-specific results that are no longer relevant are deprioritised (but not deleted — the user may travel).

**Acceptance criteria:**
- [ ] Location fields appear on the profile settings page
- [ ] Saving a location triggers the geographic discovery sweep (US-2.5.2)
- [ ] Third Spaces, partner inventory, and event results are filtered by the user's configured location
- [ ] No device geolocation APIs are used
- [ ] Location is optional — the platform functions without it, but Third Spaces will be empty

---

#### US-17.2.3 Change Password

**As a** user, **I want to** change my password **so that** I can maintain account security.

**How they accomplish it:**
1. The user navigates to Settings > Password (`/settings/password`).
2. They enter their current password and a new password (twice, for confirmation).
3. On submission, the system validates the current password and updates to the new one.

**What they see on the page:**
- Three fields: Current Password, New Password, Confirm New Password.
- Password strength indicator on the new password field.
- On success: "Password updated." On failure: "Current password is incorrect."
- No password requirements are displayed beyond a minimum length — the platform trusts the user.

**Acceptance criteria:**
- [ ] `/settings/password` renders the password change form
- [ ] The current password must be verified before the change is applied
- [ ] Password is hashed with Argon2 before storage
- [ ] Success/failure messages are clear and immediate

---

### 17.3 Notifications

#### US-17.3.1 Email Notification Preferences

**As a** user, **I want to** control which emails The Stacks sends me **so that** I only receive messages I care about — the platform should be quiet by default.

**What the user wants to accomplish:** Opt in or out of specific email notifications. The Stacks is intentionally a low-noise platform — email is reserved for important, infrequent communications.

**How they accomplish it:**
1. The user navigates to Settings > Notifications (`/settings/notifications`).
2. They see a list of email notification categories, each with a toggle.

**What they see on the page:**
- A page titled "Notifications" with a brief philosophy note in italic serif: "The Stacks aims to be a quiet place. We only email you when it matters."
- Notification categories:
  - **Terms of service changes** — always on, cannot be disabled (legal requirement). Shown as a locked toggle with a note: "Required — we'll let you know if our terms change."
  - **WishList availability** — "Get notified when a book on your WishList becomes available from a local partner or on the marketplace." Default: off.
  - **Marketplace activity** (future) — "Updates on your listings: offers received, sales confirmed, shipping updates." Default: on (when marketplace is active).
  - **Group invitations** — "When someone invites you to a group." Default: on.
  - **Event matches** — "When an event related to a book in your collection is discovered nearby." Default: off.
- Each category has a clear description and a toggle. Changes save automatically.
- No in-app notification center, no bell icon, no push notifications. Email only, and sparingly.

**Acceptance criteria:**
- [ ] `/settings/notifications` renders the notification preferences page
- [ ] Terms of service notifications cannot be disabled
- [ ] All other categories are toggleable
- [ ] Changes save automatically without a submit button
- [ ] Default states match the specification (most off by default)

---

## 18. Bookshelf — Looking for a Home

### 18.1 Browse the Looking for a Home Shelf

#### US-18.1.1 Browse the Looking for a Home Shelf

**As a** user, **I want to** browse my "Looking for a Home" shelf **so that** I can see all the books I have listed or intend to list for second-hand sale, displayed as books ready to find a new reader.

**What the user wants to accomplish:** View the books they are willing to part with, in an aesthetic that conveys transition and possibility rather than loss.

**How they accomplish it:**
1. The user clicks "Looking for a Home" in the top navigation.
2. The page transitions in with a horizontal slide (adjacent to the other bookshelves in the navigation sequence).
3. The Looking for a Home shelf loads with all books the user has placed there.

**What they see on the page:**
- **Setting:** A window ledge or market stall — a transitional space that suggests books are on their way somewhere new. The aesthetic is warm but transient: perhaps a sunny window with books propped against the glass, or a wooden crate at a street market.
- **Shelving:** Lighter, more open than the permanent shelves. The books are not tightly packed — there is breathing room between spines, suggesting they are ready to leave.
- **Lighting:** Bright, optimistic light — morning sun through a window or the open air of a market. A visual contrast with the Library's lamplight, signalling that these books are moving outward.
- **Shelf label:** "Looking for a Home" styled in the same serif typeface and brass plate convention as other shelves.
- **Books:** Spine wear on this shelf is **community-driven**, not based on the individual user's reading history. If many users across the platform have read this book (high placement count in Library shelves platform-wide), the spine shows heavy wear — well-loved and well-travelled. If the book is a recent publication with few readers, the spine is pristine and shiny. This creates a visual signal: worn spines are proven books with many readers, pristine spines are hidden gems waiting to be discovered. The community wear state is calculated from anonymised, aggregate platform data — no individual user's reading history is exposed.
- Books can arrive on this shelf from **any** other shelf, including directly from the upload flow (US-1.1.1) if the user is uploading a book specifically to sell or give away. There is no requirement that a book pass through Library or Reading Pile first.
- **Relationship to the marketplace:** This shelf is the staging area for the marketplace feature described in Section 7 (US-7.1, US-7.2). Books placed here may or may not have active listings. In the pre-marketplace phase, this shelf simply holds books the user intends to sell or give away.
- **Default visibility:** Unlike other shelves which default to "Only me", the Looking for a Home shelf defaults to "Platform users" visibility when the profile is set to discoverable — because the intent is for other users to see these books are available.

**Acceptance criteria:**
- [ ] The Looking for a Home shelf is accessible via `/looking-for-home`
- [ ] The page renders books placed on this shelf with the appropriate aesthetic
- [ ] The shelf appears in the navigation bar between Reading Pile and Search
- [ ] The shelf supports the same interactions as other bookshelves (click spine to view detail, move between shelves)
- [ ] The empty state displays an encouraging message about finding books new homes
- [ ] Swipe navigation includes this shelf in the bookshelf sequence

---

## 19. Accessibility

### 19.1 Screen Reader & Keyboard Support

#### US-19.1.1 ARIA Labels for Visual Elements

**As a** user who relies on a screen reader, **I want** the visual bookshelf, spine, and detail overlay elements to have meaningful ARIA labels **so that** I can navigate and understand my collection without relying on visual cues.

**What the user wants to accomplish:** Access all platform functionality through a screen reader, with meaningful descriptions of the visual metaphors that sighted users experience.

**How the system handles it:**
1. Every book spine element has an `aria-label` describing the book: "Book: [Title] by [Author], [Page Count] pages, on your [Shelf Name]".
2. The bookshelf container has a `role="list"` with an `aria-label`: "[Shelf Name] — [N] books".
3. Shelf rows within the bookcase have `role="listitem"` groupings.
4. The book detail overlay has `role="dialog"` with `aria-label`: "Book details: [Title] by [Author]". Focus is trapped within the overlay while it's open. Pressing Escape dismisses it.
5. Navigation items have clear labels. The display name dropdown is labelled "User menu" with items announced as "Settings" and "Sign Out".
6. Upload states (processing, verification, shelf placement) announce progress via `aria-live` regions: "Processing image...", "Book identified: [Title] by [Author]", "Added to [Shelf Name]."
7. The shelf transition animations are decorative — screen readers skip them. The destination content is announced immediately.
8. Wear state information (pristine, softened, cracking, well-read, well-loved) is included in the spine's ARIA label as a parenthetical: "(well-loved, read 3 times)".

**What they hear:**
- Navigating to a shelf: "[Shelf Name] — 12 books. List of 12 items."
- Landing on a spine: "Book: The Secret History by Donna Tartt, 559 pages, well-read."
- Opening a detail overlay: "Dialog: Book details — The Secret History by Donna Tartt."
- Upload verification: "Book identified: Piranesi by Susanna Clarke. Confirm or reject."

**Acceptance criteria:**
- [ ] All book spines have descriptive `aria-label` attributes
- [ ] Bookshelf containers use `role="list"` with shelf name and book count
- [ ] The book detail overlay uses `role="dialog"` with focus trapping
- [ ] Upload flow progress is announced via `aria-live` regions
- [ ] All interactive elements are keyboard-focusable and operable

---

#### US-19.1.2 Keyboard Navigation

**As a** keyboard-only user, **I want to** navigate between shelves, browse books, and open detail overlays using only the keyboard **so that** I can use the platform without a mouse.

**How they accomplish it:**
1. **Tab** moves focus between navigation items, then into the shelf content, then to individual book spines.
2. **Arrow keys** move between spines on a shelf (left/right within a row, up/down between rows).
3. **Enter** on a focused spine opens the book detail overlay.
4. **Escape** closes the detail overlay, returning focus to the spine that opened it.
5. Within the detail overlay, **Tab** moves between interactive elements (shelf picker, format toggles, links).
6. **Tab** from the last navigation item wraps to the first shelf content element, following standard focus order.

**Acceptance criteria:**
- [ ] All interactive elements are reachable via Tab
- [ ] Arrow key navigation works within the bookshelf grid
- [ ] Focus returns to the triggering element when an overlay is closed
- [ ] Skip links are provided to jump past navigation to main content
- [ ] Focus indicators are visible and styled consistently with the platform aesthetic

---

### 19.2 Alternative Views

#### US-19.2.1 List View Toggle

**As a** user, **I want** an alternative list view for my bookshelves **so that** I can browse my collection in a format that is more accessible, more information-dense, or better suited to certain screen sizes.

**What the user wants to accomplish:** Switch from the visual spine/shelf metaphor to a structured list that shows more metadata at a glance. This is valuable for screen reader users, users on very small screens, users with visual impairments, and anyone who prefers a data-oriented view.

**How they accomplish it:**
1. On any bookshelf page, the user clicks a "List view" toggle icon in the shelf header (next to the shelf label).
2. The view switches from the visual bookshelf to a structured list.
3. The toggle persists across page navigation (stored as a user preference). Once toggled, all shelves render in list view until the user switches back.

**What they see on the page:**
- The list view replaces the visual shelf with a clean table/list:
  - Each row shows: book cover thumbnail (small), title, author, page count, date added, shelf, format indicators, and wear state as a text label.
  - Rows are sortable by any column (click column header to sort).
  - Clicking a row opens the book detail overlay.
- The shelf's wallpaper, lighting, and spatial metaphor are not rendered in list view. The background is a clean parchment tone.
- The toggle icon is a simple grid/list icon pair, styled subtly in the shelf header. The active view is indicated.
- In list view, the "Add a Book" link remains accessible in the same position.

**Acceptance criteria:**
- [ ] A list/grid toggle is visible on all bookshelf pages
- [ ] List view displays books as sortable rows with key metadata
- [ ] The view preference persists across page navigation and sessions
- [ ] Clicking a row opens the book detail overlay
- [ ] The toggle is keyboard-accessible
- [ ] List view is the default for screen reader users (detected via `prefers-reduced-motion` or a user setting)

---

*This document covers the complete feature set of The Stacks as specified. User stories are numbered for reference and grouped by domain. Each story includes the user's goal, the interaction flow, and detailed UI descriptions consistent with the platform's dark-academic-meets-cottage-core aesthetic.*
