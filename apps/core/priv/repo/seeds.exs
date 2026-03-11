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
book1 = u.("a1b2c3d4-0000-0000-0000-000000000201")
book2 = u.("a1b2c3d4-0000-0000-0000-000000000202")
book3 = u.("a1b2c3d4-0000-0000-0000-000000000203")
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
  prefix: "op"
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
    }
  ],
  prefix: "op"
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
    }
  ],
  prefix: "op"
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
  prefix: "op"
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
    }
  ],
  prefix: "op"
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
  prefix: "op"
)

Repo.insert_all(
  "uploaded_images",
  [
    %{
      id: image1,
      book_id: book1,
      storage_path: "uploads/republic-cover.jpg",
      status: "resolved",
      uploaded_at: jan_15,
      expires_at: feb_14,
      created_at: jan_15,
      updated_at: jan_15
    }
  ],
  prefix: "op"
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
  prefix: "audit"
)

IO.puts("Seeds loaded successfully.")
