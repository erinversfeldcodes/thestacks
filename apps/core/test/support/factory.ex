defmodule Stacks.Factory do
  @moduledoc """
  ExMachina factory for test data. Use `build/2` for in-memory structs
  and `insert/2` for persisted records.
  """

  use ExMachina.Ecto, repo: Core.Repo

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

  def user_factory do
    %User{
      email: sequence(:email, &"user#{&1}@example.com"),
      password_hash: Argon2.hash_pwd_salt("password123"),
      display_name: sequence(:display_name, &"User #{&1}"),
      handle: sequence(:handle, &"reader_#{&1}"),
      role: "user",
      profile_visibility: "owner",
      age_verified: false,
      consent_analytics: false,
      email_confirmed: true
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

  def book_factory do
    %Book{
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

  def book_edition_factory do
    %BookEdition{
      isbn: sequence(:isbn, &"978074327#{String.pad_leading(to_string(&1), 4, "0")}"),
      format_label: "Paperback",
      page_count: 300,
      publisher: "Test Publisher",
      publication_year: 2020,
      is_primary: true,
      book: build(:book)
    }
  end

  def bookshelf_factory do
    %Bookshelf{
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

  def placement_factory do
    %Placement{
      position: 1,
      placed_at: DateTime.utc_now(),
      formats: [],
      visibility: "owner",
      reading_status: "to_read",
      current_page: nil,
      started_at: nil,
      finished_at: nil,
      book: build(:book),
      bookshelf: build(:bookshelf),
      shelf: build(:shelf)
    }
  end

  def uploaded_image_factory do
    %UploadedImage{
      status: "pending",
      uploaded_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 30, :day),
      user_id: Ecto.UUID.generate()
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

  def transaction_factory do
    %Transaction{
      listing: build(:listing),
      buyer: build(:user),
      seller: build(:user),
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
      country_code: "ZA"
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
      website_url: "https://example.com",
      verified: false
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

  def price_snapshot_factory do
    %PriceSnapshot{
      price_cents: 29_900,
      currency: "ZAR",
      in_stock: true,
      url: "https://example.com/book",
      scraped_at: DateTime.utc_now(),
      book: build(:book),
      store: build(:bookstore)
    }
  end

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
end
