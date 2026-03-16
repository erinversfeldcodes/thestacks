# Seed fixtures for development and dbt testing.
# Run with: mix run apps/core/priv/repo/seeds.exs
# Or via:   just test-dbt  (which resets the DB first)
#
# Dev logins:
#   owner@thestacks.app / dev-password-123  (owner role)
#   user@thestacks.app  / dev-password-456  (user role — for IDOR/E2E tests)

alias Core.Repo

# Postgrex requires binary-encoded UUIDs for :binary_id columns
u = &Ecto.UUID.dump!/1

# Fixture IDs
user1 = u.("a1b2c3d4-0000-0000-0000-000000000001")
user2 = u.("a1b2c3d4-0000-0000-0000-000000000002")
author1 = u.("a1b2c3d4-0000-0000-0000-000000000101")
author2 = u.("a1b2c3d4-0000-0000-0000-000000000102")
author3 = u.("a1b2c3d4-0000-0000-0000-000000000103")
author4 = u.("a1b2c3d4-0000-0000-0000-000000000104")
author5 = u.("a1b2c3d4-0000-0000-0000-000000000105")
book1 = u.("a1b2c3d4-0000-0000-0000-000000000201")
book2 = u.("a1b2c3d4-0000-0000-0000-000000000202")
book3 = u.("a1b2c3d4-0000-0000-0000-000000000203")
book4 = u.("a1b2c3d4-0000-0000-0000-000000000204")
book5 = u.("a1b2c3d4-0000-0000-0000-000000000205")
book6 = u.("a1b2c3d4-0000-0000-0000-000000000206")
book7 = u.("a1b2c3d4-0000-0000-0000-000000000207")
book8 = u.("a1b2c3d4-0000-0000-0000-000000000208")
book9 = u.("a1b2c3d4-0000-0000-0000-000000000209")
book10 = u.("a1b2c3d4-0000-0000-0000-000000000210")
book11 = u.("a1b2c3d4-0000-0000-0000-000000000211")
book12 = u.("a1b2c3d4-0000-0000-0000-000000000212")
book13 = u.("a1b2c3d4-0000-0000-0000-000000000213")
book14 = u.("a1b2c3d4-0000-0000-0000-000000000214")
book15 = u.("a1b2c3d4-0000-0000-0000-000000000215")
book16 = u.("a1b2c3d4-0000-0000-0000-000000000216")
book17 = u.("a1b2c3d4-0000-0000-0000-000000000217")
book18 = u.("a1b2c3d4-0000-0000-0000-000000000218")
book19 = u.("a1b2c3d4-0000-0000-0000-000000000219")
book20 = u.("a1b2c3d4-0000-0000-0000-000000000220")
shelf1 = u.("a1b2c3d4-0000-0000-0000-000000000301")
shelf2 = u.("a1b2c3d4-0000-0000-0000-000000000302")
shelf3 = u.("a1b2c3d4-0000-0000-0000-000000000303")
shelf4 = u.("a1b2c3d4-0000-0000-0000-000000000304")
shelf5 = u.("a1b2c3d4-0000-0000-0000-000000000305")
shelf6 = u.("a1b2c3d4-0000-0000-0000-000000000306")
shelf7 = u.("a1b2c3d4-0000-0000-0000-000000000307")
shelf8 = u.("a1b2c3d4-0000-0000-0000-000000000308")
shelf9 = u.("a1b2c3d4-0000-0000-0000-000000000309")
shelf10 = u.("a1b2c3d4-0000-0000-0000-000000000310")
place1 = u.("a1b2c3d4-0000-0000-0000-000000000401")
place2 = u.("a1b2c3d4-0000-0000-0000-000000000402")
place3 = u.("a1b2c3d4-0000-0000-0000-000000000403")
place4 = u.("a1b2c3d4-0000-0000-0000-000000000404")
place5 = u.("a1b2c3d4-0000-0000-0000-000000000405")
place6 = u.("a1b2c3d4-0000-0000-0000-000000000406")
place7 = u.("a1b2c3d4-0000-0000-0000-000000000407")
place8 = u.("a1b2c3d4-0000-0000-0000-000000000408")
place9 = u.("a1b2c3d4-0000-0000-0000-000000000409")
place10 = u.("a1b2c3d4-0000-0000-0000-000000000410")
place11 = u.("a1b2c3d4-0000-0000-0000-000000000411")
place12 = u.("a1b2c3d4-0000-0000-0000-000000000412")
place13 = u.("a1b2c3d4-0000-0000-0000-000000000413")
place14 = u.("a1b2c3d4-0000-0000-0000-000000000414")
place15 = u.("a1b2c3d4-0000-0000-0000-000000000415")
place16 = u.("a1b2c3d4-0000-0000-0000-000000000416")
place17 = u.("a1b2c3d4-0000-0000-0000-000000000417")
place18 = u.("a1b2c3d4-0000-0000-0000-000000000418")
place19 = u.("a1b2c3d4-0000-0000-0000-000000000419")
place20 = u.("a1b2c3d4-0000-0000-0000-000000000420")
history1 = u.("a1b2c3d4-0000-0000-0000-000000000501")
image1 = u.("a1b2c3d4-0000-0000-0000-000000000601")
audit1 = u.("a1b2c3d4-0000-0000-0000-000000000701")

jan_01 = ~U[2026-01-01 00:00:00.000000Z]
jan_10 = ~U[2026-01-10 00:00:00.000000Z]
jan_15 = ~U[2026-01-15 00:00:00.000000Z]
feb_14 = ~U[2026-02-14 00:00:00.000000Z]

# Insert in FK dependency order

Repo.insert_all(
  "users",
  [
    %{
      id: user1,
      email: "owner@thestacks.app",
      display_name: "Platform Owner",
      password_hash: Argon2.hash_pwd_salt("dev-password-123"),
      role: "owner",
      profile_visibility: "owner",
      age_verified: true,
      age_verified_at: jan_01,
      country_code: "ZA",
      city: "Johannesburg",
      consent_analytics: true,
      consent_analytics_at: jan_01,
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: user2,
      email: "user@thestacks.app",
      display_name: "Test User",
      password_hash: Argon2.hash_pwd_salt("dev-password-456"),
      role: "user",
      profile_visibility: "owner",
      age_verified: false,
      country_code: "ZA",
      city: "Cape Town",
      consent_analytics: false,
      created_at: jan_01,
      updated_at: jan_01
    }
  ],
  prefix: "op",
  on_conflict: :nothing
)

Repo.insert_all(
  "authors",
  [
    %{
      id: author1,
      name: "Ursula K. Le Guin",
      open_library_id: "OL18319A",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: author2,
      name: "Plato",
      open_library_id: "OL12823A",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: author3,
      name: "Donna Tartt",
      open_library_id: "OL34024A",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: author4,
      name: "Umberto Eco",
      open_library_id: "OL37023A",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: author5,
      name: "Kazuo Ishiguro",
      open_library_id: "OL20646A",
      created_at: jan_01,
      updated_at: jan_01
    }
  ],
  prefix: "op",
  on_conflict: :nothing
)

Repo.insert_all(
  "books",
  [
    %{
      id: book1,
      isbn: "9780062301352",
      title: "The Republic",
      author_id: author2,
      page_count: 416,
      language: "en",
      visibility_tier: "public",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: book2,
      isbn: "9780061120084",
      title: "The Left Hand of Darkness",
      author_id: author1,
      page_count: 304,
      language: "en",
      visibility_tier: "public",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: book3,
      isbn: "9780061470769",
      title: "The Dispossessed",
      author_id: author1,
      page_count: 387,
      language: "en",
      visibility_tier: "public",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: book4,
      isbn: "9780679410324",
      title: "The Secret History",
      author_id: author3,
      page_count: 559,
      language: "en",
      visibility_tier: "public",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: book5,
      isbn: "9780156030410",
      title: "The Name of the Rose",
      author_id: author4,
      page_count: 536,
      language: "en",
      visibility_tier: "public",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: book6,
      isbn: "9780571258093",
      title: "The Remains of the Day",
      author_id: author5,
      page_count: 245,
      language: "en",
      visibility_tier: "public",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: book7,
      isbn: "9780316769488",
      title: "The Catcher in the Rye",
      author_id: author3,
      page_count: 234,
      language: "en",
      visibility_tier: "public",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: book8,
      isbn: "9780060935467",
      title: "To Kill a Mockingbird",
      author_id: author3,
      page_count: 336,
      language: "en",
      visibility_tier: "public",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: book9,
      isbn: "9780743273565",
      title: "The Great Gatsby",
      author_id: author3,
      page_count: 180,
      language: "en",
      visibility_tier: "public",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: book10,
      isbn: "9780141439518",
      title: "Pride and Prejudice",
      author_id: author3,
      page_count: 432,
      language: "en",
      visibility_tier: "public",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: book11,
      isbn: "9780140449136",
      title: "Crime and Punishment",
      author_id: author4,
      page_count: 671,
      language: "en",
      visibility_tier: "public",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: book12,
      isbn: "9780060883287",
      title: "One Hundred Years of Solitude",
      author_id: author4,
      page_count: 417,
      language: "en",
      visibility_tier: "public",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: book13,
      isbn: "9780140283334",
      title: "Atonement",
      author_id: author5,
      page_count: 351,
      language: "en",
      visibility_tier: "public",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: book14,
      isbn: "9780571225385",
      title: "Never Let Me Go",
      author_id: author5,
      page_count: 288,
      language: "en",
      visibility_tier: "public",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: book15,
      isbn: "9780525559474",
      title: "Klara and the Sun",
      author_id: author5,
      page_count: 303,
      language: "en",
      visibility_tier: "public",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: book16,
      isbn: "9780062316097",
      title: "Sapiens",
      author_id: author4,
      page_count: 443,
      language: "en",
      visibility_tier: "public",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: book17,
      isbn: "9780374529260",
      title: "Middlemarch",
      author_id: author3,
      page_count: 880,
      language: "en",
      visibility_tier: "public",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: book18,
      isbn: "9780140449266",
      title: "Anna Karenina",
      author_id: author4,
      page_count: 864,
      language: "en",
      visibility_tier: "public",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: book19,
      isbn: "9780099511021",
      title: "Wolf Hall",
      author_id: author3,
      page_count: 604,
      language: "en",
      visibility_tier: "public",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: book20,
      isbn: "9780571347292",
      title: "Hamnet",
      author_id: author5,
      page_count: 372,
      language: "en",
      visibility_tier: "public",
      created_at: jan_01,
      updated_at: jan_01
    }
  ],
  prefix: "op",
  on_conflict: :nothing
)

Repo.insert_all(
  "bookshelves",
  [
    %{
      id: shelf1,
      user_id: user1,
      name: "antilibrary",
      visibility: "owner",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: shelf2,
      user_id: user1,
      name: "library",
      visibility: "owner",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: shelf3,
      user_id: user1,
      name: "wishlist",
      visibility: "owner",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: shelf4,
      user_id: user1,
      name: "reading_pile",
      visibility: "owner",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: shelf5,
      user_id: user1,
      name: "looking_for_home",
      visibility: "owner",
      created_at: jan_01,
      updated_at: jan_01
    },
    # user2's bookshelves (used for IDOR tests — separate owner, private resources)
    %{
      id: shelf6,
      user_id: user2,
      name: "antilibrary",
      visibility: "owner",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: shelf7,
      user_id: user2,
      name: "library",
      visibility: "owner",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: shelf8,
      user_id: user2,
      name: "wishlist",
      visibility: "owner",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: shelf9,
      user_id: user2,
      name: "reading_pile",
      visibility: "owner",
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: shelf10,
      user_id: user2,
      name: "looking_for_home",
      visibility: "owner",
      created_at: jan_01,
      updated_at: jan_01
    }
  ],
  prefix: "op",
  on_conflict: :nothing
)

Repo.insert_all(
  "bookshelf_placements",
  [
    %{
      id: place1,
      book_id: book1,
      bookshelf_id: shelf1,
      position: 1,
      placed_at: jan_15,
      formats: ["paperback"],
      notes: "Unread classic",
      visibility: "owner",
      created_at: jan_15,
      updated_at: jan_15
    },
    %{
      id: place2,
      book_id: book2,
      bookshelf_id: shelf2,
      position: 1,
      placed_at: jan_10,
      formats: ["paperback"],
      notes: "Favourite Le Guin",
      personal_rating: 5,
      visibility: "owner",
      created_at: jan_10,
      updated_at: jan_10
    },
    %{
      id: place3,
      book_id: book4,
      bookshelf_id: shelf2,
      position: 2,
      placed_at: jan_15,
      formats: ["hardcover"],
      visibility: "owner",
      created_at: jan_15,
      updated_at: jan_15
    },
    %{
      id: place4,
      book_id: book5,
      bookshelf_id: shelf2,
      position: 3,
      placed_at: jan_15,
      formats: ["paperback"],
      visibility: "owner",
      created_at: jan_15,
      updated_at: jan_15
    },
    %{
      id: place5,
      book_id: book6,
      bookshelf_id: shelf2,
      position: 4,
      placed_at: jan_15,
      formats: ["paperback"],
      visibility: "owner",
      created_at: jan_15,
      updated_at: jan_15
    },
    %{
      id: place6,
      book_id: book7,
      bookshelf_id: shelf2,
      position: 5,
      placed_at: jan_15,
      formats: ["paperback"],
      visibility: "owner",
      created_at: jan_15,
      updated_at: jan_15
    },
    %{
      id: place7,
      book_id: book8,
      bookshelf_id: shelf2,
      position: 6,
      placed_at: jan_15,
      formats: ["paperback"],
      visibility: "owner",
      created_at: jan_15,
      updated_at: jan_15
    },
    %{
      id: place8,
      book_id: book9,
      bookshelf_id: shelf2,
      position: 7,
      placed_at: jan_15,
      formats: ["paperback"],
      visibility: "owner",
      created_at: jan_15,
      updated_at: jan_15
    },
    %{
      id: place9,
      book_id: book10,
      bookshelf_id: shelf2,
      position: 8,
      placed_at: jan_15,
      formats: ["hardcover"],
      visibility: "owner",
      created_at: jan_15,
      updated_at: jan_15
    },
    %{
      id: place10,
      book_id: book11,
      bookshelf_id: shelf2,
      position: 9,
      placed_at: jan_15,
      formats: ["paperback"],
      visibility: "owner",
      created_at: jan_15,
      updated_at: jan_15
    },
    %{
      id: place11,
      book_id: book12,
      bookshelf_id: shelf2,
      position: 10,
      placed_at: jan_15,
      formats: ["paperback"],
      visibility: "owner",
      created_at: jan_15,
      updated_at: jan_15
    },
    %{
      id: place12,
      book_id: book13,
      bookshelf_id: shelf2,
      position: 11,
      placed_at: jan_15,
      formats: ["paperback"],
      visibility: "owner",
      created_at: jan_15,
      updated_at: jan_15
    },
    %{
      id: place13,
      book_id: book14,
      bookshelf_id: shelf2,
      position: 12,
      placed_at: jan_15,
      formats: ["paperback"],
      visibility: "owner",
      created_at: jan_15,
      updated_at: jan_15
    },
    %{
      id: place14,
      book_id: book15,
      bookshelf_id: shelf2,
      position: 13,
      placed_at: jan_15,
      formats: ["paperback"],
      visibility: "owner",
      created_at: jan_15,
      updated_at: jan_15
    },
    %{
      id: place15,
      book_id: book16,
      bookshelf_id: shelf2,
      position: 14,
      placed_at: jan_15,
      formats: ["hardcover"],
      visibility: "owner",
      created_at: jan_15,
      updated_at: jan_15
    },
    %{
      id: place16,
      book_id: book17,
      bookshelf_id: shelf2,
      position: 15,
      placed_at: jan_15,
      formats: ["hardcover"],
      visibility: "owner",
      created_at: jan_15,
      updated_at: jan_15
    },
    %{
      id: place17,
      book_id: book18,
      bookshelf_id: shelf2,
      position: 16,
      placed_at: jan_15,
      formats: ["paperback"],
      visibility: "owner",
      created_at: jan_15,
      updated_at: jan_15
    },
    %{
      id: place18,
      book_id: book19,
      bookshelf_id: shelf2,
      position: 17,
      placed_at: jan_15,
      formats: ["hardcover"],
      visibility: "owner",
      created_at: jan_15,
      updated_at: jan_15
    },
    %{
      id: place19,
      book_id: book20,
      bookshelf_id: shelf2,
      position: 18,
      placed_at: jan_15,
      formats: ["paperback"],
      visibility: "owner",
      created_at: jan_15,
      updated_at: jan_15
    },
    %{
      id: place20,
      book_id: book3,
      bookshelf_id: shelf1,
      position: 2,
      placed_at: jan_15,
      formats: ["paperback"],
      visibility: "owner",
      created_at: jan_15,
      updated_at: jan_15
    }
  ],
  prefix: "op",
  on_conflict: :nothing
)

Repo.insert_all(
  "bookshelf_placement_history",
  [
    %{
      id: history1,
      book_id: book2,
      from_bookshelf: shelf1,
      to_bookshelf: shelf2,
      moved_at: jan_10
    }
  ],
  prefix: "op",
  on_conflict: :nothing
)

Repo.insert_all(
  "uploaded_images",
  [
    %{
      id: image1,
      book_id: book1,
      storage_path: nil,
      status: "resolved",
      uploaded_at: jan_15,
      expires_at: feb_14,
      created_at: jan_15,
      updated_at: jan_15
    }
  ],
  prefix: "op",
  on_conflict: :nothing
)

Repo.insert_all(
  "audit_log",
  [
    %{
      id: audit1,
      user_id: user1,
      action: "user.registered",
      resource_type: "user",
      resource_id: user1,
      metadata: nil,
      occurred_at: jan_01
    }
  ],
  prefix: "audit",
  on_conflict: :nothing
)

IO.puts("Seeds loaded successfully.")
