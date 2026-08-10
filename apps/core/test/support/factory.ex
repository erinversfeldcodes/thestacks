defmodule Stacks.Factory do
  @moduledoc """
  ExMachina factory for test data. Use `build/2` for in-memory structs
  and `insert/2` for persisted records.
  """

  use ExMachina.Ecto, repo: Core.Repo

  import Ecto.Query, only: [from: 2]

  alias Stacks.Accounts
  alias Stacks.Accounts.User
  alias Stacks.Blog.{Post, PostBookAssociation, PostComment}
  alias Stacks.Books.{Author, Book, BookEdition, UploadedImage}

  alias Stacks.Enrichment.{
    Bookstore,
    BookstoreEvent,
    DiscoveredSource,
    PriceSnapshot,
    ReviewSnapshot,
    ThirdSpace,
    ThirdSpaceEvent
  }

  alias Stacks.Costs.PlatformCost
  alias Stacks.Marketplace.{Listing, OfferMessage, OfferThread, Transaction}
  alias Stacks.Monitoring.SourceHealthCheck
  alias Stacks.Partners.{InventoryItem, Partner}
  alias Stacks.Shelving.{Bookshelf, Placement, PlacementHistory, Shelf}
  alias Stacks.Social.{Group, GroupInvitation, GroupMember, UserBlock, VisibilityGrant}

  alias Stacks.WritingAssistant.{
    BookContentChunk,
    Embedding,
    RetrievalLog,
    Session,
    TurnFeedback,
    UserBookContentAccess
  }

  @doc """
  A user whose email is confirmed — the state `RequireConfirmedEmail` demands,
  so this is what nearly every test wants.

  "Confirmed" is not a *starting* state: it is the result of
  `Accounts.mark_confirmed/1` running over a registered, unconfirmed account
  (accounts.ex:438-446). So rather than asserting the end state by hand, this
  builds the registered state and pushes it through the very changeset
  `mark_confirmed/1` uses. The two cannot drift: if confirmation ever clears
  another field or sets a confirmed_at, the factory picks it up for free.
  """
  def user_factory do
    :unconfirmed_user
    |> build()
    |> Accounts.email_confirmation_changeset(%{
      email_confirmed: true,
      email_confirmation_token: nil
    })
    |> Ecto.Changeset.apply_changes()
  end

  @doc """
  A registered-but-unconfirmed account — the state EVERY real signup passes
  through, and the one `ExpiredUnverifiedAccountsJob` exists to reap.

  `Accounts.register/1` commits `email_confirmed: false` plus a `Phoenix.Token`
  signed with the `"email_confirm"` salt over the user's OWN id
  (accounts.ex:527-545). The id is therefore generated here rather than left to
  the database, so the token genuinely verifies — a random string would fixture
  a token no confirmation link could ever carry, and the confirmation flow
  would be untestable from the factory.
  """
  def unconfirmed_user_factory do
    id = Ecto.UUID.generate()

    %User{
      id: id,
      email: sequence(:email, &"user#{&1}@example.com"),
      password_hash: Argon2.hash_pwd_salt("password123"),
      display_name: sequence(:display_name, &"User #{&1}"),
      handle: sequence(:handle, &"reader_#{&1}"),
      role: "user",
      profile_visibility: "owner",
      age_verified: false,
      consent_analytics: false,
      email_confirmed: false,
      email_confirmation_token: Phoenix.Token.sign(CoreWeb.Endpoint, "email_confirm", id)
    }
  end

  def owner_user_factory do
    struct!(user_factory(), role: "owner")
  end

  def author_factory do
    %Author{
      name: sequence(:author_name, &"Author #{&1}"),
      bio: "A talented writer.",
      website_url: nil,
      rss_feed_url: nil,
      open_library_id: nil
    }
  end

  # A work ALWAYS ships with its primary edition. Both production creation
  # paths — `Books.create/1` (books.ex:180-200) and `Books.confirm_book/3`
  # (books.ex:1099-1120) — insert the work and its `is_primary: true` edition
  # inside ONE `Ecto.Multi`, because the ISBN hard gate means a work without a
  # verified ISBN cannot exist. A bare `%Book{}` therefore fixtures a row the
  # system cannot produce, and every assertion about `Books.primary_edition/1`
  # made against one was asserting on a shape prod never emits.
  #
  # To exercise the gate itself (or the `primary_edition/1` nil branch), use
  # `:editionless_book` — explicitly named so the invalid state is deliberate.
  def book_factory do
    %{editionless_book_factory() | editions: [build(:primary_book_edition)]}
  end

  @doc """
  A work with NO edition — the one state the ISBN hard gate forbids.

  Only for tests *about* the gate (or `primary_edition/1` returning nil).
  Everything else wants `:book`.
  """
  def editionless_book_factory do
    %Book{
      # Generated here, not by the database, so a factory can point two columns
      # at ONE work before anything is inserted — and so that accidentally
      # putting the same unsaved work on two association paths raises on
      # `books_pkey` instead of silently creating two works. See
      # `price_snapshot_factory/0`.
      id: Ecto.UUID.generate(),
      title: sequence(:title, &"Book Title #{&1}"),
      description: "A great book.",
      language: "en",
      subjects: ["fiction"],
      bisac_codes: ["FIC000000"],
      visibility_tier: "public"
    }
  end

  def book_with_author_factory do
    %{book_factory() | author: build(:author)}
  end

  # An ADDITIONAL edition of a work that already has its primary one — the only
  # shape production can reach for a second edition. `Books.merge_edition/2`
  # (books.ex:1101) and `insert_edition/4` (books.ex:1180) both force
  # `is_primary: false`, so two primaries on one work is unreachable in prod.
  # Hence `is_primary: false` here, and a default `book:` that brings its own
  # primary. Pass `book:` an existing work to hang a second edition off it.
  def book_edition_factory do
    %BookEdition{
      # Generated here, like the work's own id, so a placement can point at this
      # edition before either row is inserted (see `placement_factory/1`).
      id: Ecto.UUID.generate(),
      isbn: next_isbn(),
      format_label: "Hardcover",
      page_count: 300,
      publisher: "Test Publisher",
      publication_year: 2020,
      is_primary: false,
      # `merge_edition/2` is the only production path to a second edition and it
      # only runs after `ISBNResolver.resolve/1` returned, so a non-primary
      # edition production can reach always has an external source.
      verification_source: "open_library",
      book: build(:book)
    }
  end

  @doc """
  The primary edition a work is created WITH — never on its own.

  `book: nil` because it is inserted through the work's `has_many :editions`,
  which fills `book_id` in. `op.book_editions` has a partial unique index
  (`book_editions_one_primary_per_book`), so hanging one of these off a work
  that already has its primary edition raises — which is the point.

  Use it to pin the work's ISBN or format:

      insert(:book, editions: [build(:primary_book_edition, isbn: "9780593098233")])
  """
  def primary_book_edition_factory do
    %BookEdition{
      id: Ecto.UUID.generate(),
      isbn: next_isbn(),
      format_label: "Paperback",
      page_count: 300,
      publisher: "Test Publisher",
      publication_year: 2020,
      is_primary: true,
      # `op.book_editions.verification_source` is NOT NULL with a CHECK on the
      # value (#335 D1), so a factory that omitted it would build a row no
      # database accepts. `open_library` is the ordinary path: the moderation
      # fast path's `barcode_unverified` is the exception, and a test about it
      # should say so explicitly.
      verification_source: "open_library",
      book: nil
    }
  end

  # Production validates the EAN-13 check digit on EVERY edition write path
  # (`Books.book_edition_changeset/2` → `validate_isbn_checksum/1`,
  # books.ex:1293), so an ISBN whose 13th digit is just the next number in a
  # sequence is a value no write path would ever have accepted. Build the
  # 12-digit body from the sequence and compute the check digit.
  #
  # The `97817` block is deliberately one no fixture, seed or spec hard-codes,
  # so a generated ISBN can never collide with a literal one.
  defp next_isbn do
    sequence(:isbn, fn n ->
      with_check_digit("97817" <> String.pad_leading(to_string(n), 7, "0"))
    end)
  end

  defp with_check_digit(body) do
    sum =
      body
      |> String.graphemes()
      |> Enum.map(&String.to_integer/1)
      |> Enum.with_index()
      |> Enum.reduce(0, fn {digit, index}, acc ->
        weight = if rem(index, 2) == 0, do: 1, else: 3
        acc + digit * weight
      end)

    body <> Integer.to_string(rem(10 - rem(sum, 10), 10))
  end

  # The id is generated here rather than by the database so that a shelf and a
  # placement can be pointed at THE SAME bookshelf before anything is inserted.
  # Ecto has no identity map: the same unsaved struct reached through two
  # association paths is inserted twice, which is how the old placement factory
  # ended up with two bookshelves. See `placement_factory/1`.
  def bookshelf_factory do
    %Bookshelf{
      id: Ecto.UUID.generate(),
      name: "library",
      visibility: "owner",
      user: build(:user)
    }
  end

  def shelf_factory do
    %Shelf{
      bookshelf: build(:bookshelf),
      position: 0
    }
  end

  # The shelf is DERIVED from the bookshelf, never built beside it. Production
  # never picks the two independently: `place_book/3` (shelving.ex:329-341),
  # `reread_book/1` and `do_move_book/3` (shelving.ex:427) all resolve the
  # bookshelf first and then get-or-create *its* default shelf. Building both
  # from their own factories gave every bare `insert(:placement)` a
  # `bookshelf_id` and a `shelf.bookshelf_id` pointing at two different
  # bookshelves owned by two different users — the exact desync shelving.ex
  # documents at :418-421 as making a book "stay visible on the source and
  # never on the destination". Overriding `bookshelf:` re-homes the shelf with
  # it; override `shelf:` too only when the desync is what you are testing.
  #
  # Same reasoning as `price_snapshot_factory/0` below: two columns that
  # describe one relationship must be built from one value.
  #
  # This takes `attrs` (ExMachina's arity-1 factory form) because the derivation
  # has to see an overridden `bookshelf:` — a plain arity-0 factory is evaluated
  # BEFORE overrides are merged, so `insert(:placement, bookshelf: b)` would
  # re-home the placement and leave the shelf behind on the default one.
  #
  # Only the SHELF holds the bookshelf struct; the placement carries the id and
  # a `:loaded` view of it. Ecto has no identity map, so the same unsaved struct
  # on two association paths is inserted twice — the bookshelf must be inserted
  # by exactly one chain, and it has to be the shelf's, because `shelves` has
  # the FK that must already exist.
  def placement_factory(attrs) do
    {bookshelf, attrs} = Map.pop_lazy(attrs, :bookshelf, fn -> build(:bookshelf) end)
    {shelf, attrs} = Map.pop_lazy(attrs, :shelf, fn -> default_shelf_for(bookshelf) end)
    {book, attrs} = Map.pop_lazy(attrs, :book, fn -> build(:book) end)

    %Placement{
      position: 1,
      placed_at: DateTime.utc_now(),
      formats: [],
      visibility: "owner",
      reading_status: "to_read",
      current_page: nil,
      started_at: nil,
      finished_at: nil,
      book: book,
      # `Shelving.place_book/3` points every new placement at the work's primary
      # edition (#335 D2), so a factory placement that left this nil would build
      # a shape production stopped emitting. Derived from the work the caller
      # actually gave us — never guessed — and nil for an `:editionless_book`,
      # which is the one case production also leaves nil.
      book_edition_id: primary_edition_id_of(book),
      bookshelf_id: bookshelf.id,
      bookshelf: Ecto.put_meta(bookshelf, state: :loaded),
      shelf: shelf
    }
    |> merge_attributes(attrs)
  end

  # The edition `Shelving.primary_edition_id/1` would resolve for this work.
  # Reads the built `editions` list when it is loaded (the common case: the
  # `:book` factory brings its primary edition with it) and falls back to the
  # database for an already-persisted work whose association was not preloaded.
  defp primary_edition_id_of(%Book{editions: editions}) when is_list(editions) do
    editions
    |> Enum.sort_by(&{not &1.is_primary, &1.id})
    |> case do
      [] -> nil
      [edition | _] -> edition.id
    end
  end

  defp primary_edition_id_of(%Book{id: book_id}) when is_binary(book_id) do
    Core.Repo.one(
      from e in BookEdition,
        where: e.book_id == type(^book_id, Ecto.UUID),
        order_by: [desc: e.is_primary, asc: e.created_at, asc: e.id],
        limit: 1,
        select: e.id
    )
  end

  defp primary_edition_id_of(_book), do: nil

  # Mirrors `get_or_create_default_shelf/1` (shelving.ex:1105), which every
  # production placement path goes through. A bookshelf has ONE shelf at
  # position 0 — `op.shelves` has a unique index on (bookshelf_id, position) —
  # so two placements on the same bookshelf must land on the same shelf, not on
  # two rival position-0 shelves. A bookshelf that is already persisted is
  # looked up; an unsaved one gets its shelf built and inserted alongside it.
  defp default_shelf_for(%Bookshelf{__meta__: %{state: :loaded}} = bookshelf) do
    case Core.Repo.get_by(Shelf, bookshelf_id: bookshelf.id, position: 0) do
      nil -> build(:shelf, bookshelf: bookshelf)
      shelf -> shelf
    end
  end

  defp default_shelf_for(%Bookshelf{} = bookshelf) do
    build(:shelf, bookshelf: bookshelf)
  end

  def uploaded_image_factory do
    # user_id carries a real ON DELETE CASCADE FK to op.users since #353, so it
    # can no longer default to a throwaway random UUID (which references no user
    # and now violates the constraint). It defaults to nil — the column is
    # nullable, and the retention/telemetry/dbt tests that use a bare
    # `insert(:uploaded_image)` do not care who owns the image. Tests that need
    # a real owner pass `user_id: user.id` (a `user: build(:user)` default is
    # not used here because ExMachina rejects mixing it with a `user_id:`
    # override, which many call sites rely on).
    %UploadedImage{
      status: "pending",
      uploaded_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 30, :day),
      user_id: nil
    }
  end

  # book_id / from_bookshelf / to_bookshelf intentionally default to random
  # UUIDs, so a bare `insert(:placement_history)` WILL violate the three FKs on
  # op.bookshelf_placement_history (book_id is null: false → the failure you
  # hit first). That is BY DESIGN, not a factory bug: the history table is an
  # append-only audit trail deliberately decoupled from Ecto associations
  # (proto/persisted.exs:525-542 maps these columns as plain :binary_id, never
  # belongs_to, so a book/bookshelf delete never cascades its history away).
  # Because there is no association, ExMachina cannot lazily insert real rows
  # on insert — always override the FKs with real records, e.g. the
  # `seed_move_history/3` pattern in shelving_test.exs:
  #   insert(:placement_history, book_id: book.id,
  #     from_bookshelf: bookshelf.id, to_bookshelf: bookshelf.id)
  def placement_history_factory do
    %PlacementHistory{
      book_id: Ecto.UUID.generate(),
      from_bookshelf: Ecto.UUID.generate(),
      to_bookshelf: Ecto.UUID.generate(),
      moved_at: DateTime.utc_now()
    }
  end

  # ---------------------------------------------------------------------------
  # Social
  # ---------------------------------------------------------------------------

  def user_block_factory do
    %UserBlock{
      blocker: build(:user),
      blocked: build(:user)
    }
  end

  def group_factory do
    %Group{
      owner: build(:user),
      name: sequence(:group_name, &"Group #{&1}"),
      type: "close_friends",
      visibility: "invite_only"
    }
  end

  def group_member_factory do
    %GroupMember{
      group: build(:group),
      user: build(:user),
      role: "member"
    }
  end

  def group_invitation_factory do
    %GroupInvitation{
      group: build(:group),
      invited_by_user: build(:user),
      invited_user: build(:user),
      status: "pending"
    }
  end

  def visibility_grant_factory do
    %VisibilityGrant{
      resource_type: "bookshelf",
      resource_id: Ecto.UUID.generate(),
      granted_to: build(:user),
      granted_by: build(:user)
    }
  end

  # ---------------------------------------------------------------------------
  # Blog
  # ---------------------------------------------------------------------------

  def post_factory do
    %Post{
      user: build(:user),
      title: sequence(:post_title, &"Post #{&1}"),
      body: "Some markdown body.",
      visibility: "owner"
    }
  end

  def post_comment_factory do
    %PostComment{
      post: build(:post),
      author: build(:user),
      body: sequence(:comment_body, &"Comment #{&1}")
    }
  end

  def post_book_association_factory do
    %PostBookAssociation{
      post: build(:post),
      book: build(:book),
      confidence: 0.9,
      reasoning: "Thematic overlap.",
      source: "llm",
      visible: true
    }
  end

  # ---------------------------------------------------------------------------
  # Marketplace
  # ---------------------------------------------------------------------------

  def offer_thread_factory do
    %OfferThread{
      placement: build(:placement),
      buyer: build(:user),
      status: "open"
    }
  end

  def offer_message_factory do
    %OfferMessage{
      thread: build(:offer_thread),
      sender: build(:user),
      type: "message",
      body: "Is this still available?",
      amount_cents: nil
    }
  end

  def listing_factory do
    %Listing{
      book: build(:book),
      seller: build(:user),
      status: "draft",
      pricing_mode: "fixed",
      price_cents: 15_000,
      currency: "ZAR",
      condition: "good",
      description: "Good condition."
    }
  end

  # The seller of a transaction IS the seller of its listing — one relationship
  # spread over two columns, exactly like `price_snapshot_factory/0`. Building
  # them apart gave every transaction a seller who did not own the thing being
  # sold. `op.transactions` has no production write path yet (nothing outside
  # the generated schema references `Marketplace.Transaction`), so there is no
  # context function to mirror — which is the reason to get the shape right
  # here, before one is written against these fixtures.
  def transaction_factory do
    listing = build(:listing)

    %Transaction{
      listing: listing,
      buyer: build(:user),
      seller_id: listing.seller.id,
      seller: Ecto.put_meta(listing.seller, state: :loaded),
      amount_cents: 15_000,
      currency: "ZAR",
      payment_provider_ref: sequence(:payment_ref, &"stitch-#{&1}"),
      payment_status: "pending"
    }
  end

  # ---------------------------------------------------------------------------
  # Monitoring
  # ---------------------------------------------------------------------------

  def source_health_check_factory do
    %SourceHealthCheck{
      source_name: sequence(:source_name, &"source-#{&1}"),
      source_type: "scraper_config",
      status: "healthy",
      consecutive_failures: 0,
      total_successes: 10,
      total_failures: 0
    }
  end

  # ---------------------------------------------------------------------------
  # Costs
  # ---------------------------------------------------------------------------

  def platform_cost_factory do
    now = DateTime.utc_now()

    %PlatformCost{
      category: "infrastructure",
      service: sequence(:service_name, &"service-#{&1}"),
      description: "Monthly hosting cost.",
      amount_cents: 1500,
      currency: "USD",
      period_start: DateTime.add(now, -30, :day),
      period_end: now
    }
  end

  # ---------------------------------------------------------------------------
  # Enrichment
  # ---------------------------------------------------------------------------

  def bookstore_factory do
    %Bookstore{
      name: sequence(:store_name, &"Bookstore #{&1}"),
      website_url: "https://example.com",
      scraper_module: sequence(:scraper_module, &"za/store_#{&1}"),
      has_physical: true,
      country_code: "ZA",
      # ⚠️ Deliberately ~7 km from the `:third_space` factory's default point, not the
      # same one. The 500 m pairing rule is the thing most proximity tests are about,
      # and if the two defaults coincided every space would sit 0 km from every
      # bookshop — so those tests would pass without asserting anything. A test that
      # wants the rule satisfied must position one of them on purpose.
      latitude: -33.9500,
      longitude: 18.5000
    }
  end

  def bookstore_event_factory do
    %BookstoreEvent{
      title: sequence(:event_title, &"Book Event #{&1}"),
      description: "An exciting literary event.",
      event_date: DateTime.add(DateTime.utc_now(), 7, :day),
      location: "In-store",
      url: "https://example.com/events",
      scraped_at: DateTime.utc_now(),
      store: build(:bookstore)
    }
  end

  def third_space_factory do
    %ThirdSpace{
      name: sequence(:space_name, &"Third Space #{&1}"),
      type: "cafe",
      city: "Cape Town",
      country_code: "ZA",
      # A fixed point (central Cape Town), deliberately NOT a sequence: geo tests
      # assert on distances, and a per-space offset would make every radius assertion
      # depend on insertion order. Tests that care about position set it explicitly.
      latitude: -33.9249,
      longitude: 18.4241,
      website_url: "https://example.com",
      verified: false,
      # Defaults to NOT curated. Curation is the second tier of the 500 m rule, so a
      # factory that curated by default would let every fixture qualify on quality it
      # was never given — and the tier-2 tests would pass without asserting the trade-off.
      curated: false
    }
  end

  def third_space_event_factory do
    starts_at = DateTime.add(DateTime.utc_now(), 7, :day)

    %ThirdSpaceEvent{
      title: sequence(:space_event_title, &"Space Event #{&1}"),
      description: "A community gathering.",
      event_date: starts_at,
      ends_at: DateTime.add(starts_at, 2, :hour),
      recurrence: nil,
      related_authors: [],
      source_url: "https://example.com/events",
      scraped_at: DateTime.utc_now(),
      space: build(:third_space)
    }
  end

  def discovered_source_factory do
    %DiscoveredSource{
      name: sequence(:source_name, &"Discovered Source #{&1}"),
      type: "bookshop",
      url: sequence(:source_url, &"https://source-#{&1}.example.com"),
      confidence: nil,
      discovered_via: "search:bookshops",
      discovered_at: DateTime.utc_now(),
      status: "pending_review"
    }
  end

  # The edition is the grain, and `book` must be *that edition's* book — the two
  # columns describe one relationship, so building them independently would
  # manufacture rows the production write path cannot produce.
  #
  # Naming the same struct on both association paths was not enough, and was in
  # fact the very bug the old comment warned about: Ecto has no identity map, so
  # it inserted that work TWICE and the two columns ended up pointing at two
  # different works. Only the EDITION holds the struct; the snapshot carries its
  # id plus a `:loaded` view, which Ecto reads and does not re-insert.
  #
  # Arity-1 (like `placement_factory/1`) so an overridden `book_edition:` still
  # determines `book`, and so a caller passing both does not collide with a
  # `book_id` this factory set from the default.
  def price_snapshot_factory(attrs) do
    {edition, attrs} = Map.pop_lazy(attrs, :book_edition, fn -> build(:book_edition) end)
    {book, attrs} = Map.pop_lazy(attrs, :book, fn -> book_of(edition) end)

    %PriceSnapshot{
      price_cents: 29_900,
      currency: "ZAR",
      in_stock: true,
      url: "https://example.com/book",
      scraped_at: DateTime.utc_now(),
      book_edition: edition,
      book_id: book.id,
      book: Ecto.put_meta(book, state: :loaded),
      store: build(:bookstore)
    }
    |> merge_attributes(attrs)
  end

  defp book_of(%BookEdition{book: %Book{} = book}), do: book
  defp book_of(%BookEdition{book_id: id}) when is_binary(id), do: Core.Repo.get!(Book, id)

  def review_snapshot_factory do
    %ReviewSnapshot{
      source: "goodreads",
      source_url: "https://goodreads.com/book/show/12345",
      sentiment_score: 0.78,
      summary: "Readers enjoyed this book.",
      rating: 4.2,
      rating_count: 1250,
      scraped_at: DateTime.utc_now(),
      stale_after: DateTime.add(DateTime.utc_now(), 30, :day),
      book: build(:book)
    }
  end

  def partner_factory do
    %Partner{
      name: "The Corner Bookshop",
      business_type: "bookshop",
      contact_email: sequence(:partner_email, &"partner#{&1}@example.com"),
      website_url: "https://cornerbookshop.example.com",
      status: "pending",
      api_key_prefix: nil,
      hmac_secret: nil,
      approved_by_id: nil,
      approved_at: nil
    }
  end

  def partner_inventory_item_factory do
    %InventoryItem{
      partner: build(:partner),
      book_edition: build(:book_edition),
      price_cents: 1500,
      condition: "good",
      quantity: 1,
      synced_at: DateTime.utc_now()
    }
  end

  # ── Writing Assistant / Embeddings (Issue #183) ──────────────────────────

  def blog_assistant_session_factory do
    %Session{
      user: build(:user),
      status: "active",
      topic: sequence(:wa_topic, &"Writing topic #{&1}"),
      model: "together/BAAI/bge-m3",
      started_at: DateTime.utc_now()
    }
  end

  def turn_feedback_factory do
    %TurnFeedback{
      session: build(:blog_assistant_session),
      turn_index: 0,
      rating: "up",
      comment: "Helpful suggestion."
    }
  end

  def retrieval_log_factory do
    %RetrievalLog{
      session: build(:blog_assistant_session),
      query: sequence(:wa_query, &"retrieval query #{&1}"),
      retrieved_ids: [],
      scores: [],
      turn_index: 0
    }
  end

  def user_book_content_access_factory do
    %UserBookContentAccess{
      user: build(:user),
      book: build(:book),
      access_type: "granted",
      granted_at: DateTime.utc_now()
    }
  end

  def embedding_factory do
    %Embedding{
      user: build(:user),
      source_type: "shelf",
      source_id: Ecto.UUID.generate(),
      title: sequence(:embedding_title, &"Embedded item #{&1}"),
      shelf: "library",
      content_date: DateTime.utc_now(),
      embedding: Pgvector.new(List.duplicate(0.1, 1024))
    }
  end

  def book_content_chunk_factory do
    %BookContentChunk{
      book: build(:book),
      chunk_index: 0,
      content: "Shared corpus text — not personal.",
      token_count: 5,
      embedding: Pgvector.new(List.duplicate(0.1, 1024))
    }
  end

  def library_import_factory do
    %Stacks.Imports.LibraryImport{
      user: build(:user),
      source: "goodreads",
      filename: "goodreads_library_export.csv",
      status: "enqueued",
      row_count: 0
    }
  end

  def library_import_row_factory do
    %Stacks.Imports.LibraryImportRow{
      import: build(:library_import),
      row_number: sequence(:library_import_row_number, & &1),
      raw_title: "1984",
      raw_author: "George Orwell",
      raw_isbn13: "9780141036144",
      goodreads_shelf: "read",
      created_at: DateTime.utc_now()
    }
  end
end
