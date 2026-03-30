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
        metadata: %{ecto_type: :map},
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
    # Partners
    # -------------------------------------------------------------------------
    %{
      proto_file: "stacks/internal/v1/partner.proto",
      proto_message: "Partner",
      table_name: "partners",
      schema_prefix: "op",
      ecto_module: Stacks.Partners.Partner,
      ecto_path: "lib/stacks/gen/partners/partner.ex",
      dbt_path: "stg_partners.sql",
      timestamps: :standard,
      field_overrides: %{
        approved_by_id: %{ecto_type: :binary_id},
        hmac_secret: %{dbt_exclude: true},
        third_space_id: %{belongs_to: Stacks.Enrichment.ThirdSpace}
      }
    },
    %{
      proto_file: "stacks/internal/v1/partner.proto",
      proto_message: "PartnerInventoryItem",
      table_name: "partner_inventory",
      schema_prefix: "op",
      ecto_module: Stacks.Partners.InventoryItem,
      ecto_path: "lib/stacks/gen/partners/inventory_item.ex",
      dbt_path: "stg_partner_inventory.sql",
      timestamps: :standard,
      migration_exists: false,
      dbt_grant: true,
      indexes: [
        %{
          name: "partner_inventory_partner_edition_uniq",
          columns: [:partner_id, :book_edition_id],
          unique: true
        }
      ],
      field_overrides: %{
        partner_id: %{belongs_to: Stacks.Partners.Partner, null: false},
        book_edition_id: %{belongs_to: Stacks.Books.BookEdition, null: false},
        price_cents: %{null: false},
        condition: %{null: false},
        quantity: %{default: 1, null: false},
        synced_at: %{null: false, default: {:fragment, "NOW()"}}
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
      virtual_fields: [password: :string],
      derive_jason: [
        :id,
        :email,
        :display_name,
        :role,
        :profile_visibility,
        :age_verified,
        :consent_analytics,
        :created_at,
        :updated_at
      ],
      field_overrides: %{
        role: %{default: "user"},
        profile_visibility: %{default: "owner"},
        country_code: %{default: "ZA"},
        age_verified: %{default: false},
        consent_analytics: %{default: false},
        # generated_always: true suppresses default and cast — Postgres generates this column.
        onboarding_completed: %{generated_always: true},
        onboarding_steps: %{ecto_type: :map, default: %{}},
        notify_wishlist_availability: %{default: false},
        notify_marketplace: %{default: true},
        notify_group_invitations: %{default: true},
        notify_event_matches: %{default: false},
        email_confirmed: %{default: false},
        # Security-sensitive fields — exclude from dbt analytics
        password_hash: %{dbt_exclude: true},
        password_reset_token: %{dbt_exclude: true},
        password_reset_sent_at: %{dbt_exclude: true},
        email_confirmation_token: %{dbt_exclude: true}
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
      derive_jason: [
        :id,
        :title,
        :description,
        :language,
        :subjects,
        :bisac_codes,
        :visibility_tier,
        :created_at,
        :updated_at
      ],
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
        # API-only fields — no DB column, excluded from Ecto schema and dbt
        author: %{api_only: true},
        editions: %{api_only: true},
        edition_count: %{api_only: true},
        primary_edition: %{api_only: true},
        community_read_count: %{api_only: true}
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
      field_overrides: %{}
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
      derive_jason: [
        :id,
        :isbn,
        :format_label,
        :cover_image_url,
        :page_count,
        :publisher,
        :publication_year,
        :open_library_id,
        :google_books_id,
        :is_primary,
        :created_at,
        :updated_at
      ],
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
        visibility: %{default: "owner"},
        reading_status: %{
          dbt_tests: [
            :not_null,
            {:accepted_values, ["to_read", "reading", "completed", "abandoned"]}
          ]
        }
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
      derive_jason: [
        :id,
        :user_id,
        :title,
        :body,
        :visibility,
        :visibility_group_id,
        :published_at,
        :created_at,
        :updated_at
      ],
      associations: [
        {:has_many, :book_associations, Stacks.Blog.PostBookAssociation, foreign_key: :post_id}
      ],
      field_overrides: %{
        user_id: %{belongs_to: Stacks.Accounts.User},
        visibility: %{default: "owner"},
        visibility_group_id: %{belongs_to: Stacks.Social.Group},
        published_at: %{ecto_type: :utc_datetime_usec},
        # API-only fields — no DB column, excluded from Ecto schema and dbt
        associations: %{api_only: true}
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
      derive_jason: [
        :id,
        :post_id,
        :book_id,
        :confidence,
        :reasoning,
        :source,
        :visible,
        :created_at
      ],
      field_overrides: %{
        post_id: %{belongs_to: Stacks.Blog.Post},
        book_id: %{belongs_to: Stacks.Books.Book},
        source: %{default: "llm"},
        visible: %{default: true},
        # API-only fields — no DB column, excluded from Ecto schema and dbt
        book_title: %{api_only: true},
        status: %{api_only: true}
      }
    },
    %{
      proto_file: "stacks/common/v1/blog.proto",
      proto_message: "PostComment",
      table_name: "post_comments",
      schema_prefix: "op",
      ecto_module: Stacks.Blog.PostComment,
      ecto_path: "lib/stacks/gen/blog/post_comment.ex",
      dbt_path: "stg_post_comments.sql",
      timestamps: false,
      migration_exists: false,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        post_id: %{
          belongs_to: Stacks.Blog.Post,
          references_table: :blog_posts,
          on_delete: :delete_all,
          null: false
        },
        author_id: %{
          belongs_to: Stacks.Accounts.User,
          references_table: :users,
          on_delete: :nilify_all
        },
        parent_id: %{ecto_type: :binary_id},
        created_at: %{ecto_type: :utc_datetime_usec, default: {:fragment, "NOW()"}}
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
      derive_jason: [:id, :owner_id, :name, :type, :visibility, :created_at, :updated_at],
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
      derive_jason: [:id, :group_id, :user_id, :role, :joined_at, :created_at],
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
      derive_jason: [
        :id,
        :group_id,
        :invited_by_id,
        :invited_user_id,
        :status,
        :responded_at,
        :created_at
      ],
      field_overrides: %{
        group_id: %{belongs_to: Stacks.Social.Group},
        invited_by_id: %{belongs_to: Stacks.Accounts.User, assoc_name: :invited_by_user},
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
      derive_jason: [
        :id,
        :resource_type,
        :resource_id,
        :granted_to_id,
        :granted_by_id,
        :created_at
      ],
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
      derive_jason: [
        :id,
        :blocker_id,
        :blocked_id,
        :created_at
      ],
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
      derive_jason: [
        :id,
        :status,
        :pricing_mode,
        :price_cents,
        :currency,
        :condition,
        :description,
        :contact_info,
        :photo_urls,
        :listed_at,
        :expires_at,
        :sold_at,
        :created_at,
        :updated_at
      ],
      field_overrides: %{
        book_id: %{belongs_to: Stacks.Books.Book},
        seller_id: %{belongs_to: Stacks.Accounts.User},
        status: %{default: "draft"},
        currency: %{default: "ZAR"},
        photo_urls: %{ecto_type: {:array, :string}, default: []},
        listed_at: %{ecto_type: :utc_datetime_usec},
        expires_at: %{ecto_type: :utc_datetime_usec},
        sold_at: %{ecto_type: :utc_datetime_usec},
        # API-only fields — no DB column, excluded from Ecto schema and dbt
        book: %{api_only: true}
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
      derive_jason: [
        :id,
        :placement_id,
        :buyer_id,
        :status,
        :created_at,
        :updated_at
      ],
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
      derive_jason: [
        :id,
        :thread_id,
        :sender_id,
        :type,
        :body,
        :amount_cents,
        :created_at
      ],
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
      derive_jason: [
        :id,
        :listing_id,
        :offer_id,
        :buyer_id,
        :seller_id,
        :amount_cents,
        :currency,
        :payment_provider_ref,
        :payment_status,
        :shipping_provider_ref,
        :shipping_status,
        :shipping_cost_cents,
        :completed_at,
        :created_at
      ],
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
        config_generated: %{ecto_type: :map},
        # PII — exclude from dbt analytics
        exclusion_email: %{dbt_exclude: true}
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
        verified: %{default: false},
        opted_out: %{default: false}
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
  ],

  # -------------------------------------------------------------------------
  # ProtoJSON.Gen — base serializer functions generated from proto messages.
  # Each entry produces a function in StacksWeb.ProtoJSON.Gen that extracts
  # all proto fields from an Ecto struct. The hand-written ProtoJSON module
  # composes these with business logic (field subsetting, computed fields).
  # -------------------------------------------------------------------------
  proto_json: [
    %{
      proto_file: "stacks/common/v1/book.proto",
      proto_message: "Book",
      function_name: :book,
      skip_fields: [:author, :editions, :edition_count, :primary_edition, :community_read_count],
      field_overrides: %{}
    },
    %{
      proto_file: "stacks/common/v1/book.proto",
      proto_message: "Author",
      function_name: :author,
      skip_fields: [],
      field_overrides: %{}
    },
    %{
      proto_file: "stacks/common/v1/book.proto",
      proto_message: "Edition",
      function_name: :edition,
      skip_fields: [:book_id],
      field_overrides: %{}
    },
    %{
      proto_file: "stacks/common/v1/user.proto",
      proto_message: "User",
      function_name: :user,
      skip_fields: [
        :password_hash,
        :email_confirmation_token,
        :password_reset_token,
        :password_reset_sent_at
      ],
      field_overrides: %{}
    },
    %{
      proto_file: "stacks/common/v1/placement.proto",
      proto_message: "Placement",
      function_name: :placement,
      skip_fields: [],
      field_overrides: %{}
    },
    %{
      proto_file: "stacks/common/v1/blog.proto",
      proto_message: "BlogPost",
      function_name: :blog_post,
      skip_fields: [:associations],
      field_overrides: %{}
    },
    %{
      proto_file: "stacks/common/v1/blog.proto",
      proto_message: "BookAssociation",
      function_name: :book_association,
      # book_title, status, created_at are computed by ProtoJSON, not struct fields
      skip_fields: [:post_id, :book_title, :status, :created_at],
      field_overrides: %{}
    },
    %{
      proto_file: "stacks/common/v1/listing.proto",
      proto_message: "Listing",
      function_name: :listing,
      skip_fields: [:book, :seller_id],
      field_overrides: %{}
    }
  ]
}
