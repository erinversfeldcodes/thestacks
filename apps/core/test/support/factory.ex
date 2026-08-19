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
  alias Stacks.Feedback.Entry, as: FeedbackEntry

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
  alias Stacks.Shelving
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

  @doc """
      An edition OF a work — by default a second one, hung off a work the factory
      builds for it.

      Two things follow the work rather than being fixed here. Which work: naming
      it as `book:` (a struct) or `book_id:` (an id) attaches the edition to THAT
      work instead of minting another, and only one of the two is ever set on the
      struct — setting both makes Ecto refuse the insert outright ("cannot change
      belongs_to association `book` because there is already a change setting its
      foreign key").

      And whether it is primary: `Books.create/1` writes a work's FIRST edition
      with `is_primary: true` and every later merge with `false`
      (books.ex:197-211, books.ex:787-800), so a work whose only edition is
      secondary is a state no write path produces. Hanging this off an
      `:editionless_book` therefore yields the primary edition; hanging it off a
      work that already has one yields a secondary, which is what keeps the
      `book_editions_one_primary_per_book` partial index satisfied.
  """
  def book_edition_factory(attrs) do
    {work, attrs} = pop_work(attrs)

    %BookEdition{
      id: Ecto.UUID.generate(),
      isbn: next_isbn(),
      format_label: "Hardcover",
      page_count: 300,
      publisher: "Test Publisher",
      publication_year: 2020,
      is_primary: work_has_no_editions?(work),
      verification_source: "open_library"
    }
    |> attach_work(work)
    |> merge_attributes(attrs)
  end

  defp pop_work(attrs) do
    cond do
      Map.has_key?(attrs, :book) -> {Map.fetch!(attrs, :book), Map.drop(attrs, [:book, :book_id])}
      Map.has_key?(attrs, :book_id) -> Map.pop!(attrs, :book_id)
      true -> {build(:book), attrs}
    end
  end

  defp attach_work(edition, %Book{} = book), do: %{edition | book: book}
  defp attach_work(edition, book_id) when is_binary(book_id), do: %{edition | book_id: book_id}
  defp attach_work(edition, _work), do: edition

  # A work carrying its editions in memory answers for itself; one known only by
  # id has to be asked. Order matters — a *built* `:book` already holds an unsaved
  # primary edition that no query can see yet, and calling this one primary too
  # would insert two.
  defp work_has_no_editions?(%Book{editions: editions}) when is_list(editions), do: editions == []

  defp work_has_no_editions?(%Book{id: book_id}) when is_binary(book_id),
    do: work_has_no_editions?(book_id)

  defp work_has_no_editions?(book_id) when is_binary(book_id) do
    not Core.Repo.exists?(from e in BookEdition, where: e.book_id == type(^book_id, Ecto.UUID))
  end

  defp work_has_no_editions?(_work), do: true

  @doc """
      The primary edition a work is created WITH — never on its own.

      `book: nil` because it is inserted through the work's `has_many:editions`,
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
      verification_source: "open_library",
      book: nil
    }
  end

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

  @doc """
      ONE of a user's bookshelves — not their whole set.

      A real account does not start with five bookshelves and does not
      necessarily end with them either: `Shelving.get_or_create_bookshelf/2`
      mints each one lazily, the first time that account places a book on it or
      sets its visibility (shelving.ex:1210). So a user owning nothing but a
      `library` is a state the write path really produces, and this factory is
      free to hand out one shelf. What it is not free to do is name it something
      `bookshelf_changeset/2` would reject — hence the check below. A test that
      means "the user's bookshelves" wants `insert_user_with_bookshelves/1`.
  """
  def bookshelf_factory(attrs) do
    {user, attrs} = Map.pop_lazy(attrs, :user, fn -> build(:user) end)

    %Bookshelf{
      id: Ecto.UUID.generate(),
      name: "library",
      visibility: "owner"
    }
    |> merge_attributes(attrs)
    |> assert_shelvable(user)
    |> Map.put(:user, user)
  end

  # The five names and the audience ladder belong to the write path, so ask it
  # rather than restating it. `op.bookshelf_name` and `op.visibility_level` are
  # postgres enums, so an insert would be refused anyway — but only on insert,
  # and only as `invalid input value for enum`, which names neither the factory
  # nor the rule. `build/2` gets no such refusal at all, which is how a struct
  # carrying a bookshelf no account can own reaches a test that never persists it.
  defp assert_shelvable(%Bookshelf{} = bookshelf, user) do
    changeset =
      Shelving.bookshelf_changeset(%Bookshelf{}, %{
        user_id: user.id,
        name: bookshelf.name,
        visibility: bookshelf.visibility
      })

    if changeset.valid? do
      bookshelf
    else
      raise ArgumentError,
            "no write path can create this bookshelf: " <>
              inspect(changeset.errors) <> " — see Shelving.bookshelf_changeset/2"
    end
  end

  @doc """
      A user who owns all five named bookshelves, accumulated the way an account
      accumulates them.

      Registration does not create them (accounts.ex never mentions a bookshelf);
      each appears the first time the account reaches for it. So this walks that
      same lazy path once per name through `Shelving.set_bookshelf_visibility/3`,
      leaving rows the write path wrote rather than rows shaped to look like it.
      Returns the user; reach the shelves through `Shelving.get_bookshelf/2` or
      `Shelving.list_user_bookshelves/1`.
  """
  def insert_user_with_bookshelves(attrs \\ []) do
    user = insert(:user, attrs)

    Enum.each(Shelving.bookshelf_names(), fn name ->
      {:ok, _bookshelf} = Shelving.set_bookshelf_visibility(user.id, name, "owner")
    end)

    user
  end

  def shelf_factory do
    %Shelf{
      bookshelf: build(:bookshelf),
      position: 0
    }
  end

  @doc """
      A book on a bookshelf, in a reading state that bookshelf could hold.

      Two rules, and they are separate. The dates are not independent of the
      status: `Shelving.update_reading_progress/3` stamps `started_at` on the
      first move to `"reading"` and `finished_at` on `"completed"`
      (shelving.ex:865-873), so `"reading"` with a nil `started_at`, or
      `"completed"` with a nil `finished_at`, are rows no reader could produce,
      whatever bookshelf they sit on. Those two are unconditional, and they
      apply to the status the placement ENDS with — ask for `reading_status:
      "completed"` on a wishlist and the `finished_at` follows. A started_at on
      a completed or abandoned book is the weaker claim that you read some of
      what you finished or gave up on, and only a default.

      The status itself is only a default, chosen from the bookshelf: a reading
      pile holds what is being read, a library what has been finished, and the
      rest what has not been started. It is a default rather than a rule because
      `place_book/5` never writes the column at all — every placement lands on
      the `op.bookshelf_placements.reading_status` default of `"to_read"` and
      moves only when the reader says so, so a `to_read` library book is real
      too. Say `reading_status:` when the test depends on which one it is.

      The timeline collapses onto `placed_at`, since that is the only moment the
      factory knows about; pass `started_at:`/`finished_at:` to spread it out.
  """
  def placement_factory(attrs) do
    {bookshelf, attrs} = Map.pop_lazy(attrs, :bookshelf, fn -> build(:bookshelf) end)
    {shelf, attrs} = Map.pop_lazy(attrs, :shelf, fn -> default_shelf_for(bookshelf) end)
    {book, attrs} = Map.pop_lazy(attrs, :book, fn -> build(:book) end)

    %Placement{
      position: 1,
      placed_at: DateTime.utc_now(),
      formats: [],
      visibility: "owner",
      reading_status: reading_status_on(bookshelf),
      current_page: nil,
      book: book,
      book_edition_id: primary_edition_id_of(book),
      bookshelf_id: bookshelf.id,
      bookshelf: Ecto.put_meta(bookshelf, state: :loaded),
      shelf: shelf
    }
    |> merge_attributes(attrs)
    |> stamp_reading_dates(attrs)
  end

  defp reading_status_on(%Bookshelf{name: "reading_pile"}), do: "reading"
  defp reading_status_on(%Bookshelf{name: "library"}), do: "completed"
  defp reading_status_on(%Bookshelf{}), do: "to_read"

  defp stamp_reading_dates(%Placement{} = placement, attrs) do
    started_at = pinned_or(attrs, :started_at, placement, &started_at_for/1)
    finished_at = pinned_or(attrs, :finished_at, placement, &finished_at_for/1)

    %{placement | started_at: started_at, finished_at: finished_at}
  end

  defp pinned_or(attrs, field, placement, derive) do
    if Map.has_key?(attrs, field), do: Map.fetch!(attrs, field), else: derive.(placement)
  end

  defp started_at_for(%Placement{reading_status: status, placed_at: placed_at})
       when status in ["reading", "completed", "abandoned"],
       do: placed_at

  defp started_at_for(%Placement{}), do: nil

  defp finished_at_for(%Placement{reading_status: "completed", placed_at: placed_at}),
    do: placed_at

  defp finished_at_for(%Placement{}), do: nil

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

  defp default_shelf_for(%Bookshelf{__meta__: %{state: :loaded}} = bookshelf) do
    case Core.Repo.get_by(Shelf, bookshelf_id: bookshelf.id, position: 0) do
      nil -> build(:shelf, bookshelf: bookshelf)
      shelf -> shelf
    end
  end

  defp default_shelf_for(%Bookshelf{} = bookshelf) do
    build(:shelf, bookshelf: bookshelf)
  end

  @doc """
      An image somebody uploaded — so it has an uploader, and a place the bytes
      went.

      Both write paths take the `user_id` from the authenticated session and
      derive the storage key from the row's own id
      (`Uploads.store_upload/2`/`init_upload/2` → `insert_uploaded_image/4`,
      uploads.ex:51-125), so an ownerless row is not something a user can
      produce — it is what erasure used to LEAVE BEHIND before
      `uploaded_images_user_id_fkey` was added with `ON DELETE CASCADE`. That
      makes the default load-bearing rather than cosmetic: an image with no
      owner is an image no erasure query reaches. Tests that want that state
      say so with `:orphaned_uploaded_image`.
  """
  def uploaded_image_factory(attrs) do
    {owner, attrs} = pop_owner(attrs)
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    %UploadedImage{
      id: id,
      storage_path: "uploads/#{id}",
      status: "pending",
      uploaded_at: now,
      expires_at: DateTime.add(now, 30, :day)
    }
    |> attach_owner(owner)
    |> merge_attributes(attrs)
  end

  @doc """
      An uploaded image with nobody attached — the pre-cascade leftover, and the
      only thing `:uploaded_image` will not build for you.
  """
  def orphaned_uploaded_image_factory do
    uploaded_image_factory(%{user_id: nil})
  end

  defp pop_owner(attrs) do
    cond do
      Map.has_key?(attrs, :user) -> {Map.fetch!(attrs, :user), Map.drop(attrs, [:user, :user_id])}
      Map.has_key?(attrs, :user_id) -> Map.pop!(attrs, :user_id)
      true -> {build(:user), attrs}
    end
  end

  defp attach_owner(image, %User{} = user), do: %{image | user: user}
  defp attach_owner(image, user_id) when is_binary(user_id), do: %{image | user_id: user_id}
  defp attach_owner(image, _owner), do: image

  def placement_history_factory do
    %PlacementHistory{
      book_id: Ecto.UUID.generate(),
      from_bookshelf: Ecto.UUID.generate(),
      to_bookshelf: Ecto.UUID.generate(),
      moved_at: DateTime.utc_now()
    }
  end

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

  def post_factory do
    %Post{
      user: build(:user),
      title: sequence(:post_title, &"Post #{&1}"),
      body: "Some markdown body.",
      visibility: "owner"
    }
  end

  def post_syndication_factory do
    %Stacks.Blog.PostSyndication{
      post: build(:post),
      target: "substack",
      method: "export",
      canonical_url: "https://thestacks.test/blog/00000000-0000-0000-0000-000000000000"
    }
  end

  def post_comment_factory do
    %PostComment{
      post: build(:post),
      author: build(:user),
      body: sequence(:comment_body, &"Comment #{&1}")
    }
  end

  def feedback_entry_factory do
    %FeedbackEntry{
      user: build(:user),
      body: sequence(:feedback_body, &"Something I noticed #{&1}."),
      page_context: "/library"
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

  def bookstore_factory do
    %Bookstore{
      name: sequence(:store_name, &"Bookstore #{&1}"),
      website_url: "https://example.com",
      scraper_module: sequence(:scraper_module, &"za/store_#{&1}"),
      has_physical: true,
      country_code: "ZA",
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
      latitude: -33.9249,
      longitude: 18.4241,
      website_url: "https://example.com",
      verified: false,
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
