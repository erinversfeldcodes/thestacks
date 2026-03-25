%{
  version: 1,
  tables: [
    # -------------------------------------------------------------------------
    # Internal / Infrastructure
    # -------------------------------------------------------------------------
    %{
      proto_file: "stacks/internal/v1/event_bus.proto",
      proto_message: "EventEnvelope",
      table_name: "event_log",
      schema_prefix: "op",
      ecto_module: Stacks.Events.EventLog,
      ecto_path: "lib/stacks/gen/events/event_log.ex",
      dbt_path: "stg_event_log.sql",
      timestamps: false,
      migration_exists: true,
      dbt_grant: true,
      indexes: [
        %{
          name: "idx_event_log_type_agg",
          columns: [:event_type, :aggregate_id, {:desc, :occurred_at}]
        }
      ],
      field_overrides: %{
        aggregate_id: %{ecto_type: :binary_id, null: false},
        event_type: %{null: false},
        aggregate_type: %{null: false},
        payload: %{ecto_type: :map, null: false},
        metadata: %{ecto_type: :map, null: false, default: {:fragment, "'{}'::jsonb"}},
        schema_version: %{default: 1, null: false},
        occurred_at: %{null: false, default: {:fragment, "NOW()"}}
      }
    },
    %{
      proto_file: "stacks/monitoring/v1/source_health_check.proto",
      proto_message: "SourceHealthCheck",
      table_name: "source_health_checks",
      schema_prefix: "op",
      ecto_module: Stacks.Monitoring.SourceHealthCheck,
      ecto_path: "lib/stacks/gen/monitoring/source_health_check.ex",
      dbt_path: "stg_source_health_checks.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: true,
      indexes: [
        %{
          name: "source_health_checks_source_name_index",
          columns: [:source_name],
          unique: true
        }
      ],
      field_overrides: %{
        source_name: %{null: false},
        source_type: %{null: false},
        consecutive_failures: %{default: 0, null: false},
        total_successes: %{default: 0, null: false},
        total_failures: %{default: 0, null: false},
        status: %{default: "healthy", null: false}
      }
    },
    %{
      proto_file: "stacks/internal/v1/audit.proto",
      proto_message: "AuditEntry",
      table_name: "audit_log",
      schema_prefix: "audit",
      ecto_module: Stacks.Audit.Entry,
      ecto_path: "lib/stacks/gen/audit/entry.ex",
      dbt_path: "stg_audit_log.sql",
      timestamps: false,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        user_id: %{ecto_type: :binary_id},
        resource_id: %{ecto_type: :binary_id},
        metadata: %{ecto_type: :map}
      }
    },

    # -------------------------------------------------------------------------
    # Accounts
    # -------------------------------------------------------------------------
    %{
      proto_file: "stacks/common/v1/user.proto",
      proto_message: "User",
      table_name: "users",
      schema_prefix: "op",
      ecto_module: Stacks.Accounts.User,
      ecto_path: "lib/stacks/gen/accounts/user.ex",
      dbt_path: "stg_users.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        role: %{default: "user"},
        profile_visibility: %{default: "owner"},
        country_code: %{default: "ZA"},
        age_verified: %{default: false},
        consent_analytics: %{default: false},
        onboarding_completed: %{default: false},
        notify_wishlist_availability: %{default: false},
        notify_marketplace: %{default: true},
        notify_group_invitations: %{default: true},
        notify_event_matches: %{default: false},
        email_confirmed: %{default: false}
      }
    },

    # -------------------------------------------------------------------------
    # Books
    # -------------------------------------------------------------------------
    %{
      proto_file: "stacks/common/v1/book.proto",
      proto_message: "Book",
      table_name: "books",
      schema_prefix: "op",
      ecto_module: Stacks.Books.Book,
      ecto_path: "lib/stacks/gen/books/book.ex",
      dbt_path: "stg_books.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      associations: [
        {:has_many, :editions, Stacks.Books.BookEdition, foreign_key: :book_id}
      ],
      field_overrides: %{
        # DB fields
        title: %{null: false},
        author_id: %{belongs_to: Stacks.Books.Author},
        subjects: %{ecto_type: {:array, :string}, default: []},
        bisac_codes: %{ecto_type: {:array, :string}, default: []},
        visibility_tier: %{default: "public"},
        # API-only fields — not DB columns
        author: %{skip: true},
        editions: %{skip: true},
        edition_count: %{skip: true},
        primary_edition: %{skip: true},
        community_read_count: %{skip: true}
      }
    },
    %{
      proto_file: "stacks/common/v1/book.proto",
      proto_message: "Author",
      table_name: "authors",
      schema_prefix: "op",
      ecto_module: Stacks.Books.Author,
      ecto_path: "lib/stacks/gen/books/author.ex",
      dbt_path: "stg_authors.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        # Proto uses "website" but DB column is "website_url"
        website: %{skip: true}
      }
    },
    %{
      proto_file: "stacks/common/v1/book.proto",
      proto_message: "Edition",
      table_name: "book_editions",
      schema_prefix: "op",
      ecto_module: Stacks.Books.BookEdition,
      ecto_path: "lib/stacks/gen/books/book_edition.ex",
      dbt_path: "stg_book_editions.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        book_id: %{belongs_to: Stacks.Books.Book},
        is_primary: %{default: false}
      }
    },
    %{
      proto_file: "stacks/common/v1/upload.proto",
      proto_message: "UploadedImage",
      table_name: "uploaded_images",
      schema_prefix: "op",
      ecto_module: Stacks.Books.UploadedImage,
      ecto_path: "lib/stacks/gen/books/uploaded_image.ex",
      dbt_path: "stg_uploaded_images.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        status: %{default: "pending"},
        book_ids: %{ecto_type: {:array, :binary_id}, default: []},
        book_id: %{belongs_to: Stacks.Books.Book},
        book_edition_id: %{belongs_to: Stacks.Books.BookEdition}
      }
    },

    # -------------------------------------------------------------------------
    # Shelving
    # -------------------------------------------------------------------------
    %{
      proto_file: "stacks/common/v1/placement.proto",
      proto_message: "Bookshelf",
      table_name: "bookshelves",
      schema_prefix: "op",
      ecto_module: Stacks.Shelving.Bookshelf,
      ecto_path: "lib/stacks/gen/shelving/bookshelf.ex",
      dbt_path: "stg_bookshelves.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      associations: [
        {:has_many, :placements, Stacks.Shelving.Placement, foreign_key: :bookshelf_id}
      ],
      field_overrides: %{
        user_id: %{belongs_to: Stacks.Accounts.User},
        visibility: %{default: "owner"},
        visibility_group_id: %{ecto_type: :binary_id}
      }
    },
    %{
      proto_file: "stacks/common/v1/placement.proto",
      proto_message: "Placement",
      table_name: "bookshelf_placements",
      schema_prefix: "op",
      ecto_module: Stacks.Shelving.Placement,
      ecto_path: "lib/stacks/gen/shelving/placement.ex",
      dbt_path: "stg_bookshelf_placements.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        book_id: %{belongs_to: Stacks.Books.Book},
        bookshelf_id: %{belongs_to: Stacks.Shelving.Bookshelf},
        formats: %{ecto_type: {:array, :string}, default: []},
        visibility: %{default: "owner"}
      }
    },
    %{
      proto_file: "stacks/common/v1/placement.proto",
      proto_message: "PlacementHistory",
      table_name: "bookshelf_placement_history",
      schema_prefix: "op",
      ecto_module: Stacks.Shelving.PlacementHistory,
      ecto_path: "lib/stacks/gen/shelving/placement_history.ex",
      dbt_path: "stg_bookshelf_placement_history.sql",
      timestamps: false,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        book_id: %{ecto_type: :binary_id},
        from_bookshelf: %{ecto_type: :binary_id},
        to_bookshelf: %{ecto_type: :binary_id}
      }
    },

    # -------------------------------------------------------------------------
    # Blog
    # -------------------------------------------------------------------------
    %{
      proto_file: "stacks/common/v1/blog.proto",
      proto_message: "BlogPost",
      table_name: "blog_posts",
      schema_prefix: "op",
      ecto_module: Stacks.Blog.Post,
      ecto_path: "lib/stacks/gen/blog/post.ex",
      dbt_path: "stg_blog_posts.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      associations: [
        {:has_many, :book_associations, Stacks.Blog.PostBookAssociation, foreign_key: :post_id}
      ],
      field_overrides: %{
        user_id: %{belongs_to: Stacks.Accounts.User},
        visibility: %{default: "owner"},
        visibility_group_id: %{belongs_to: Stacks.Social.Group},
        # API-only fields — not DB columns
        associations: %{skip: true}
      }
    },
    %{
      proto_file: "stacks/common/v1/blog.proto",
      proto_message: "BookAssociation",
      table_name: "post_book_associations",
      schema_prefix: "op",
      ecto_module: Stacks.Blog.PostBookAssociation,
      ecto_path: "lib/stacks/gen/blog/post_book_association.ex",
      dbt_path: "stg_post_book_associations.sql",
      timestamps: {:standard, updated_at: false},
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        post_id: %{belongs_to: Stacks.Blog.Post},
        book_id: %{belongs_to: Stacks.Books.Book},
        source: %{default: "llm"},
        visible: %{default: true},
        # API-only fields — not DB columns
        book_title: %{skip: true},
        status: %{skip: true},
        created_at: %{skip: true}
      }
    },

    # -------------------------------------------------------------------------
    # Costs
    # -------------------------------------------------------------------------
    %{
      proto_file: "stacks/common/v1/costs.proto",
      proto_message: "PlatformCost",
      table_name: "platform_costs",
      schema_prefix: "op",
      ecto_module: Stacks.Costs.PlatformCost,
      ecto_path: "lib/stacks/gen/costs/platform_cost.ex",
      dbt_path: "stg_platform_costs.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        currency: %{default: "USD"}
      }
    },

    # -------------------------------------------------------------------------
    # Social
    # -------------------------------------------------------------------------
    %{
      proto_file: "stacks/common/v1/social.proto",
      proto_message: "Group",
      table_name: "groups",
      schema_prefix: "op",
      ecto_module: Stacks.Social.Group,
      ecto_path: "lib/stacks/gen/social/group.ex",
      dbt_path: "stg_groups.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      associations: [
        {:has_many, :members, Stacks.Social.GroupMember, foreign_key: :group_id},
        {:has_many, :invitations, Stacks.Social.GroupInvitation, foreign_key: :group_id}
      ],
      field_overrides: %{
        owner_id: %{belongs_to: Stacks.Accounts.User},
        visibility: %{default: "invite_only"}
      }
    },
    %{
      proto_file: "stacks/common/v1/social.proto",
      proto_message: "GroupMember",
      table_name: "group_members",
      schema_prefix: "op",
      ecto_module: Stacks.Social.GroupMember,
      ecto_path: "lib/stacks/gen/social/group_member.ex",
      dbt_path: "stg_group_members.sql",
      timestamps: {:standard, updated_at: false},
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        group_id: %{belongs_to: Stacks.Social.Group},
        user_id: %{belongs_to: Stacks.Accounts.User},
        role: %{default: "member"}
      }
    },
    %{
      proto_file: "stacks/common/v1/social.proto",
      proto_message: "GroupInvitation",
      table_name: "group_invitations",
      schema_prefix: "op",
      ecto_module: Stacks.Social.GroupInvitation,
      ecto_path: "lib/stacks/gen/social/group_invitation.ex",
      dbt_path: "stg_group_invitations.sql",
      timestamps: {:standard, updated_at: false},
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        group_id: %{belongs_to: Stacks.Social.Group},
        invited_by_id: %{belongs_to: Stacks.Accounts.User},
        invited_user_id: %{belongs_to: Stacks.Accounts.User},
        status: %{default: "pending"}
      }
    },
    %{
      proto_file: "stacks/common/v1/social.proto",
      proto_message: "VisibilityGrant",
      table_name: "visibility_grants",
      schema_prefix: "op",
      ecto_module: Stacks.Social.VisibilityGrant,
      ecto_path: "lib/stacks/gen/social/visibility_grant.ex",
      dbt_path: "stg_visibility_grants.sql",
      timestamps: {:standard, updated_at: false},
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        resource_id: %{ecto_type: :binary_id},
        granted_to_id: %{belongs_to: Stacks.Accounts.User},
        granted_by_id: %{belongs_to: Stacks.Accounts.User}
      }
    },
    %{
      proto_file: "stacks/common/v1/social.proto",
      proto_message: "UserBlock",
      table_name: "user_blocks",
      schema_prefix: "op",
      ecto_module: Stacks.Social.UserBlock,
      ecto_path: "lib/stacks/gen/social/user_block.ex",
      dbt_path: "stg_user_blocks.sql",
      timestamps: {:standard, updated_at: false},
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        blocker_id: %{belongs_to: Stacks.Accounts.User},
        blocked_id: %{belongs_to: Stacks.Accounts.User}
      }
    },

    # -------------------------------------------------------------------------
    # Marketplace
    # -------------------------------------------------------------------------
    %{
      proto_file: "stacks/common/v1/listing.proto",
      proto_message: "Listing",
      table_name: "listings",
      schema_prefix: "op",
      ecto_module: Stacks.Marketplace.Listing,
      ecto_path: "lib/stacks/gen/marketplace/listing.ex",
      dbt_path: "stg_listings.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        book_id: %{belongs_to: Stacks.Books.Book},
        seller_id: %{belongs_to: Stacks.Accounts.User},
        status: %{default: "draft"},
        currency: %{default: "ZAR"},
        photo_urls: %{ecto_type: {:array, :string}, default: []},
        # API-only fields — not DB columns
        book: %{skip: true}
      }
    },
    %{
      proto_file: "stacks/common/v1/marketplace.proto",
      proto_message: "OfferThread",
      table_name: "offer_threads",
      schema_prefix: "op",
      ecto_module: Stacks.Marketplace.OfferThread,
      ecto_path: "lib/stacks/gen/marketplace/offer_thread.ex",
      dbt_path: "stg_offer_threads.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      associations: [
        {:has_many, :messages, Stacks.Marketplace.OfferMessage, foreign_key: :thread_id}
      ],
      field_overrides: %{
        placement_id: %{belongs_to: Stacks.Shelving.Placement},
        buyer_id: %{belongs_to: Stacks.Accounts.User},
        status: %{default: "open"}
      }
    },
    %{
      proto_file: "stacks/common/v1/marketplace.proto",
      proto_message: "OfferMessage",
      table_name: "offer_messages",
      schema_prefix: "op",
      ecto_module: Stacks.Marketplace.OfferMessage,
      ecto_path: "lib/stacks/gen/marketplace/offer_message.ex",
      dbt_path: "stg_offer_messages.sql",
      timestamps: {:standard, updated_at: false},
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        thread_id: %{belongs_to: Stacks.Marketplace.OfferThread},
        sender_id: %{belongs_to: Stacks.Accounts.User}
      }
    },
    %{
      proto_file: "stacks/common/v1/marketplace.proto",
      proto_message: "Transaction",
      table_name: "transactions",
      schema_prefix: "op",
      ecto_module: Stacks.Marketplace.Transaction,
      ecto_path: "lib/stacks/gen/marketplace/transaction.ex",
      dbt_path: "stg_transactions.sql",
      timestamps: {:standard, updated_at: false},
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        listing_id: %{belongs_to: Stacks.Marketplace.Listing},
        offer_id: %{ecto_type: :binary_id},
        buyer_id: %{belongs_to: Stacks.Accounts.User},
        seller_id: %{belongs_to: Stacks.Accounts.User},
        currency: %{default: "ZAR"},
        payment_status: %{default: "pending"}
      }
    },

    # -------------------------------------------------------------------------
    # Enrichment
    # -------------------------------------------------------------------------
    %{
      proto_file: "stacks/common/v1/enrichment.proto",
      proto_message: "DiscoveredSource",
      table_name: "discovered_sources",
      schema_prefix: "op",
      ecto_module: Stacks.Enrichment.DiscoveredSource,
      ecto_path: "lib/stacks/gen/enrichment/discovered_source.ex",
      dbt_path: "stg_discovered_sources.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        config_generated: %{ecto_type: :map}
      }
    },
    %{
      proto_file: "stacks/common/v1/enrichment.proto",
      proto_message: "ReviewSnapshot",
      table_name: "review_snapshots",
      schema_prefix: "op",
      ecto_module: Stacks.Enrichment.ReviewSnapshot,
      ecto_path: "lib/stacks/gen/enrichment/review_snapshot.ex",
      dbt_path: "stg_review_snapshots.sql",
      timestamps: false,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        book_id: %{belongs_to: Stacks.Books.Book}
      }
    },
    %{
      proto_file: "stacks/common/v1/enrichment.proto",
      proto_message: "Bookstore",
      table_name: "bookstores",
      schema_prefix: "op",
      ecto_module: Stacks.Enrichment.Bookstore,
      ecto_path: "lib/stacks/gen/enrichment/bookstore.ex",
      dbt_path: "stg_bookstores.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        has_physical: %{default: false},
        country_code: %{default: "ZA"}
      }
    },
    %{
      proto_file: "stacks/common/v1/enrichment.proto",
      proto_message: "PriceSnapshot",
      table_name: "price_snapshots",
      schema_prefix: "op",
      ecto_module: Stacks.Enrichment.PriceSnapshot,
      ecto_path: "lib/stacks/gen/enrichment/price_snapshot.ex",
      dbt_path: "stg_price_snapshots.sql",
      timestamps: false,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        book_id: %{belongs_to: Stacks.Books.Book},
        store_id: %{belongs_to: Stacks.Enrichment.Bookstore},
        currency: %{default: "ZAR"}
      }
    },
    %{
      proto_file: "stacks/common/v1/enrichment.proto",
      proto_message: "BookstoreEvent",
      table_name: "bookstore_events",
      schema_prefix: "op",
      ecto_module: Stacks.Enrichment.BookstoreEvent,
      ecto_path: "lib/stacks/gen/enrichment/bookstore_event.ex",
      dbt_path: "stg_bookstore_events.sql",
      timestamps: false,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        store_id: %{belongs_to: Stacks.Enrichment.Bookstore},
        author_id: %{belongs_to: Stacks.Books.Author}
      }
    },
    %{
      proto_file: "stacks/common/v1/enrichment.proto",
      proto_message: "ThirdSpace",
      table_name: "third_spaces",
      schema_prefix: "op",
      ecto_module: Stacks.Enrichment.ThirdSpace,
      ecto_path: "lib/stacks/gen/enrichment/third_space.ex",
      dbt_path: "stg_third_spaces.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        country_code: %{default: "ZA"},
        verified: %{default: false}
      }
    },
    %{
      proto_file: "stacks/common/v1/enrichment.proto",
      proto_message: "ThirdSpaceEvent",
      table_name: "third_space_events",
      schema_prefix: "op",
      ecto_module: Stacks.Enrichment.ThirdSpaceEvent,
      ecto_path: "lib/stacks/gen/enrichment/third_space_event.ex",
      dbt_path: "stg_third_space_events.sql",
      timestamps: false,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        space_id: %{belongs_to: Stacks.Enrichment.ThirdSpace},
        related_authors: %{ecto_type: {:array, :string}}
      }
    }
  ]
}
