%{
  version: 1,
  tables: [
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
    %{
      proto_file: "stacks/infra/v1/book_cache.proto",
      proto_message: "IsbnResolverCacheEntry",
      table_name: "isbn_resolver_cache",
      schema_prefix: "cache",
      ecto_module: Stacks.Books.IsbnResolverCacheEntry,
      ecto_path: "lib/stacks/gen/books/isbn_resolver_cache_entry.ex",
      dbt_path: "stg_isbn_resolver_cache.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: false,
      skip_dbt: true,
      indexes: [
        %{
          name: "isbn_resolver_cache_isbn_index",
          columns: [:isbn],
          unique: true
        },
        %{
          name: "isbn_resolver_cache_expires_at_index",
          columns: [:expires_at]
        }
      ],
      field_overrides: %{
        isbn: %{null: false},
        outcome: %{null: false},
        metadata: %{ecto_type: :map},
        expires_at: %{null: false}
      }
    },
    %{
      proto_file: "stacks/infra/v1/book_cache.proto",
      proto_message: "TitleSearchCacheEntry",
      table_name: "title_search_cache",
      schema_prefix: "cache",
      ecto_module: Stacks.Books.TitleSearchCacheEntry,
      ecto_path: "lib/stacks/gen/books/title_search_cache_entry.ex",
      dbt_path: "stg_title_search_cache.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: false,
      skip_dbt: true,
      indexes: [
        %{
          name: "title_search_cache_key_index",
          columns: [:cache_key],
          unique: true
        },
        %{
          name: "title_search_cache_expires_at_index",
          columns: [:expires_at]
        }
      ],
      field_overrides: %{
        cache_key: %{null: false},
        outcome: %{null: false},
        metadata: %{ecto_type: :map},
        expires_at: %{null: false}
      }
    },
    %{
      proto_file: "stacks/infra/v1/feed_cache.proto",
      proto_message: "FeedCacheEntry",
      table_name: "feed_cache",
      schema_prefix: "op",
      ecto_module: Stacks.Feeds.FeedCacheEntry,
      ecto_path: "lib/stacks/gen/feeds/feed_cache_entry.ex",
      dbt_path: "stg_feed_cache.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: false,
      skip_dbt: true,
      indexes: [
        %{
          name: "feed_cache_bookshelf_id_unique_index",
          columns: [:bookshelf_id],
          unique: true
        }
      ],
      field_overrides: %{
        bookshelf_id: %{
          belongs_to: Stacks.Shelving.Bookshelf,
          references_table: :bookshelves,
          on_delete: :delete_all,
          null: false
        },
        atom_xml: %{null: false},
        etag: %{null: false}
      }
    },
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
        handle: %{null: false, dbt_tests: [:unique]},
        country_code: %{default: "ZA"},
        age_verified: %{default: false},
        consent_analytics: %{default: false},
        consent_writing_assistant: %{default: false},
        syndication_default: %{default: true, null: false},
        onboarding_completed: %{generated_always: true},
        onboarding_steps: %{ecto_type: :map, default: %{}},
        notify_wishlist_availability: %{default: false},
        notify_marketplace: %{default: true},
        notify_group_invitations: %{default: true},
        notify_event_matches: %{default: false},
        email_confirmed: %{default: false},
        password_hash: %{dbt_exclude: true},
        password_reset_token: %{dbt_exclude: true},
        password_reset_sent_at: %{dbt_exclude: true},
        email_confirmation_token: %{dbt_exclude: true},
        # The pending-change quartet: one fact in four columns, none of which the
        # warehouse has a question for. `pending_email` is an address the reader
        # typed (personal data); the two tokens are credentials.
        pending_email: %{dbt_exclude: true},
        pending_email_token: %{dbt_exclude: true},
        pending_email_sent_at: %{dbt_exclude: true},
        pending_email_revert_token: %{dbt_exclude: true},
        failed_login_count: %{default: 0, null: false, dbt_exclude: true},
        failed_login_first_at: %{dbt_exclude: true},
        locked_until: %{dbt_exclude: true},
        lockout_duration_seconds: %{dbt_exclude: true}
      }
    },
    %{
      proto_file: "stacks/common/v1/user.proto",
      proto_message: "InviteCode",
      table_name: "invite_codes",
      schema_prefix: "op",
      ecto_module: Stacks.Accounts.InviteCode,
      ecto_path: "lib/stacks/gen/accounts/invite_code.ex",
      dbt_path: "stg_invite_codes.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: true,
      indexes: [
        %{name: "invite_codes_code_hash_index", columns: [:code_hash], unique: true},
        %{name: "invite_codes_created_at_index", columns: [{:desc, :created_at}]}
      ],
      field_overrides: %{
        code_hash: %{null: false, dbt_exclude: true},
        code_prefix: %{null: false},
        note: %{dbt_exclude: true},
        invited_email: %{dbt_exclude: true},
        max_uses: %{default: 1, null: false},
        use_count: %{default: 0, null: false},
        issued_by_id: %{
          belongs_to: Stacks.Accounts.User,
          references_table: :users,
          on_delete: :nilify_all
        },
        redeemed_by_id: %{
          belongs_to: Stacks.Accounts.User,
          references_table: :users,
          on_delete: :nilify_all
        }
      }
    },
    %{
      proto_file: "stacks/common/v1/import.proto",
      proto_message: "LibraryImport",
      table_name: "library_imports",
      schema_prefix: "op",
      ecto_module: Stacks.Imports.LibraryImport,
      ecto_path: "lib/stacks/gen/imports/library_import.ex",
      dbt_path: "stg_library_imports.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: true,
      indexes: [
        %{
          name: "library_imports_user_id_created_at_index",
          columns: [:user_id, {:desc, :created_at}]
        }
      ],
      field_overrides: %{
        user_id: %{
          belongs_to: Stacks.Accounts.User,
          references_table: :users,
          on_delete: :delete_all,
          null: false
        },
        source: %{
          default: "goodreads",
          null: false,
          dbt_tests: [{:accepted_values, ["goodreads"]}]
        },
        filename: %{dbt_exclude: true},
        status: %{
          default: "enqueued",
          null: false,
          dbt_tests: [{:accepted_values, ["enqueued", "running", "complete", "failed"]}]
        },
        row_count: %{default: 0, null: false},
        processed_count: %{default: 0, null: false},
        shelved_count: %{default: 0, null: false},
        duplicate_count: %{default: 0, null: false},
        unverified_count: %{default: 0, null: false},
        unreadable_count: %{default: 0, null: false}
      }
    },
    %{
      proto_file: "stacks/common/v1/import.proto",
      proto_message: "LibraryImportRow",
      table_name: "library_import_rows",
      schema_prefix: "op",
      ecto_module: Stacks.Imports.LibraryImportRow,
      ecto_path: "lib/stacks/gen/imports/library_import_row.ex",
      dbt_path: "stg_library_import_rows.sql",
      timestamps: false,
      migration_exists: true,
      dbt_grant: false,
      skip_dbt: true,
      indexes: [
        %{
          name: "library_import_rows_import_id_row_number_index",
          columns: [:import_id, :row_number],
          unique: true
        },
        %{
          name: "library_import_rows_import_id_outcome_index",
          columns: [:import_id, :outcome]
        }
      ],
      field_overrides: %{
        import_id: %{
          belongs_to: Stacks.Imports.LibraryImport,
          references_table: :library_imports,
          on_delete: :delete_all,
          null: false
        },
        row_number: %{null: false},
        raw_rating: %{default: 0, null: false},
        raw_read_count: %{default: 0, null: false},
        raw_owned_copies: %{default: 0, null: false},
        book_id: %{
          belongs_to: Stacks.Books.Book,
          references_table: :books,
          on_delete: :nilify_all
        },
        placement_id: %{
          belongs_to: Stacks.Shelving.Placement,
          references_table: :bookshelf_placements,
          on_delete: :nilify_all
        }
      }
    },
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
        title: %{null: false},
        author_id: %{belongs_to: Stacks.Books.Author},
        subjects: %{ecto_type: {:array, :string}, default: []},
        bisac_codes: %{ecto_type: {:array, :string}, default: []},
        visibility_tier: %{
          default: "public",
          dbt_tests: [{:accepted_values, ["public", "age_gated"]}]
        },
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
        book_id: %{
          belongs_to: Stacks.Books.Book,
          dbt_tests: [{:relationships, "stg_books"}]
        },
        is_primary: %{default: false},
        verification_source: %{
          null: false,
          dbt_tests: [
            {:accepted_values, ["open_library", "google_books", "barcode_unverified"]}
          ]
        }
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
        status: %{
          default: "pending",
          null: false,
          dbt_tests: [
            {:accepted_values, ["pending", "resolved", "rejected"]}
          ]
        },
        storage_path: %{
          dbt_exclude: true
        },
        book_ids: %{
          ecto_type: {:array, :binary_id},
          default: [],
          dbt_tests: [{:not_null, "status = 'resolved'"}]
        },
        book_id: %{
          belongs_to: Stacks.Books.Book,
          dbt_tests: [{:relationships, "stg_books", "status = 'resolved'"}]
        },
        book_edition_id: %{belongs_to: Stacks.Books.BookEdition},
        user_id: %{ecto_type: :binary_id, belongs_to: Stacks.Accounts.User}
      }
    },
    %{
      proto_file: "stacks/common/v1/placement.proto",
      proto_message: "Shelf",
      table_name: "shelves",
      schema_prefix: "op",
      ecto_module: Stacks.Shelving.Shelf,
      ecto_path: "lib/stacks/gen/shelving/shelf.ex",
      dbt_path: "stg_shelves.sql",
      timestamps: false,
      migration_exists: false,
      dbt_grant: true,
      indexes: [],
      associations: [
        {:belongs_to, :bookshelf, Stacks.Shelving.Bookshelf, foreign_key: :bookshelf_id},
        {:has_many, :placements, Stacks.Shelving.Placement, foreign_key: :shelf_id}
      ],
      field_overrides: %{
        bookshelf_id: %{belongs_to: Stacks.Shelving.Bookshelf}
      }
    },
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
        {:has_many, :placements, Stacks.Shelving.Placement, foreign_key: :bookshelf_id},
        {:has_many, :shelves, Stacks.Shelving.Shelf, foreign_key: :bookshelf_id}
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
        book_id: %{
          belongs_to: Stacks.Books.Book,
          dbt_tests: [{:relationships, "stg_books"}]
        },
        bookshelf_id: %{
          belongs_to: Stacks.Shelving.Bookshelf,
          dbt_tests: [{:relationships, "stg_bookshelves"}]
        },
        shelf_id: %{belongs_to: Stacks.Shelving.Shelf},
        book_edition_id: %{
          belongs_to: Stacks.Books.BookEdition,
          references_table: :book_editions,
          on_delete: :nilify_all,
          dbt_tests: [{:relationships, "stg_book_editions"}]
        },
        formats: %{ecto_type: {:array, :string}, default: []},
        source: %{
          default: "manual",
          null: false,
          dbt_tests: [{:accepted_values, ["manual", "upload", "goodreads_import"]}]
        },
        visibility: %{default: "owner"},
        reading_status: %{
          dbt_tests: [
            :not_null,
            {:accepted_values, ["to_read", "reading", "completed", "abandoned"]}
          ]
        },
        notes: %{dbt_exclude: true}
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
        book_id: %{ecto_type: :binary_id, dbt_tests: [{:relationships, "stg_books"}]},
        from_bookshelf: %{
          ecto_type: :binary_id,
          dbt_tests: [{:relationships, "stg_bookshelves"}]
        },
        to_bookshelf: %{ecto_type: :binary_id, dbt_tests: [{:relationships, "stg_bookshelves"}]}
      }
    },
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
        :updated_at,
        :syndicated
      ],
      associations: [
        {:has_many, :book_associations, Stacks.Blog.PostBookAssociation, foreign_key: :post_id}
      ],
      field_overrides: %{
        user_id: %{belongs_to: Stacks.Accounts.User},
        visibility: %{default: "owner"},
        visibility_group_id: %{belongs_to: Stacks.Social.Group},
        published_at: %{ecto_type: :utc_datetime_usec},
        syndicated: %{default: true, null: false},
        associations: %{api_only: true},
        author_display_name: %{api_only: true},
        author_handle: %{api_only: true}
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
        book_title: %{api_only: true},
        status: %{api_only: true}
      }
    },
    %{
      proto_file: "stacks/common/v1/blog.proto",
      proto_message: "PostSyndication",
      table_name: "post_syndications",
      schema_prefix: "op",
      ecto_module: Stacks.Blog.PostSyndication,
      ecto_path: "lib/stacks/gen/blog/post_syndication.ex",
      dbt_path: "stg_post_syndications.sql",
      timestamps: {:standard, updated_at: false},
      migration_exists: true,
      # Warehouse-safe by construction: ids, a target, a method, two URLs and a
      # timestamp — no free text. The canonical URL embeds the post UUID, not a
      # title-derived slug (story §11: a slug in the warehouse would be title
      # text in the warehouse; revisit if slugs ever land).
      dbt_grant: true,
      indexes: [],
      derive_jason: [
        :id,
        :post_id,
        :target,
        :method,
        :canonical_url,
        :syndicated_url,
        :created_at
      ],
      field_overrides: %{
        post_id: %{
          belongs_to: Stacks.Blog.Post,
          references_table: :blog_posts,
          on_delete: :delete_all,
          null: false
        },
        target: %{
          default: "substack",
          null: false,
          dbt_tests: [{:accepted_values, ["substack"]}]
        },
        method: %{
          null: false,
          dbt_tests: [{:accepted_values, ["rss", "export"]}]
        },
        canonical_url: %{null: false}
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
    %{
      proto_file: "stacks/common/v1/feedback.proto",
      proto_message: "FeedbackEntry",
      table_name: "feedback_entries",
      schema_prefix: "op",
      ecto_module: Stacks.Feedback.Entry,
      ecto_path: "lib/stacks/gen/feedback/entry.ex",
      dbt_path: "stg_feedback_entries.sql",
      timestamps: false,
      migration_exists: false,
      dbt_grant: false,
      # No staging model, deliberately: `body` is free text a reader wrote, and
      # the wh schema has no erasure path — a copy there would outlive
      # delete_user_data/1 permanently. Volume questions are answerable from
      # the feedback.submitted event, which carries no body.
      skip_dbt: true,
      indexes: [
        %{name: "feedback_entries_created_at_index", columns: [{:desc, :created_at}]},
        %{name: "feedback_entries_user_id_index", columns: [:user_id]}
      ],
      field_overrides: %{
        user_id: %{
          belongs_to: Stacks.Accounts.User,
          references_table: :users,
          on_delete: :delete_all,
          null: false
        },
        body: %{null: false},
        created_at: %{ecto_type: :utc_datetime_usec, null: false, default: {:fragment, "NOW()"}}
      }
    },
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
        visibility: %{default: "invite_only"},
        # User-authored free text that can carry a person's name — the
        # placements.notes discipline applies; counts are enough for wh.
        name: %{dbt_exclude: true}
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
        # Seller free text and a direct contact handle — the same class as a
        # placement note or an upload's storage key: the warehouse has no
        # question that needs them.
        description: %{dbt_exclude: true},
        contact_info: %{dbt_exclude: true},
        status: %{default: "draft"},
        currency: %{default: "ZAR"},
        photo_urls: %{ecto_type: {:array, :string}, default: []},
        listed_at: %{ecto_type: :utc_datetime_usec},
        expires_at: %{ecto_type: :utc_datetime_usec},
        sold_at: %{ecto_type: :utc_datetime_usec},
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
        sender_id: %{belongs_to: Stacks.Accounts.User},
        # A private message between two readers. Offer analytics need the
        # amount and the type, never what they said to each other.
        body: %{dbt_exclude: true}
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
        # Handles into the payment and shipping providers. They resolve to a
        # named individual's payment or delivery record on the other side, and
        # revenue analytics is served by the amount and the status.
        payment_provider_ref: %{dbt_exclude: true},
        shipping_provider_ref: %{dbt_exclude: true},
        currency: %{default: "ZAR"},
        payment_status: %{default: "pending"}
      }
    },
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
      indexes: [
        %{
          name: "idx_bookstores_lat_lng",
          columns: [:latitude, :longitude]
        }
      ],
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
        book_edition_id: %{belongs_to: Stacks.Books.BookEdition, null: false},
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
      indexes: [
        %{
          name: "idx_third_spaces_lat_lng",
          columns: [:latitude, :longitude]
        }
      ],
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
    },
    %{
      proto_file: "stacks/common/v1/writing_assistant.proto",
      proto_message: "BlogAssistantSession",
      table_name: "blog_assistant_sessions",
      schema_prefix: "op",
      ecto_module: Stacks.WritingAssistant.Session,
      ecto_path: "lib/stacks/gen/writing_assistant/session.ex",
      dbt_path: "stg_blog_assistant_sessions.sql",
      timestamps: :standard,
      migration_exists: false,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        user_id: %{
          belongs_to: Stacks.Accounts.User,
          references_table: :users,
          on_delete: :delete_all,
          null: false
        },
        status: %{default: "active", null: false},
        started_at: %{ecto_type: :utc_datetime_usec},
        topic: %{dbt_exclude: true}
      }
    },
    %{
      proto_file: "stacks/common/v1/writing_assistant.proto",
      proto_message: "TurnFeedback",
      table_name: "turn_feedback",
      schema_prefix: "op",
      ecto_module: Stacks.WritingAssistant.TurnFeedback,
      ecto_path: "lib/stacks/gen/writing_assistant/turn_feedback.ex",
      dbt_path: "stg_turn_feedback.sql",
      timestamps: {:standard, updated_at: false},
      migration_exists: false,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        session_id: %{
          belongs_to: Stacks.WritingAssistant.Session,
          references_table: :blog_assistant_sessions,
          on_delete: :delete_all,
          null: false
        },
        turn_index: %{null: false},
        rating: %{dbt_tests: [{:accepted_values, ["up", "down"]}]},
        comment: %{dbt_exclude: true}
      }
    },
    %{
      proto_file: "stacks/common/v1/writing_assistant.proto",
      proto_message: "RetrievalLog",
      table_name: "retrieval_log",
      schema_prefix: "op",
      ecto_module: Stacks.WritingAssistant.RetrievalLog,
      ecto_path: "lib/stacks/gen/writing_assistant/retrieval_log.ex",
      dbt_path: "stg_retrieval_log.sql",
      timestamps: {:standard, updated_at: false},
      migration_exists: false,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        session_id: %{
          belongs_to: Stacks.WritingAssistant.Session,
          references_table: :blog_assistant_sessions,
          on_delete: :delete_all,
          null: false
        },
        query: %{dbt_exclude: true},
        retrieved_ids: %{ecto_type: {:array, :binary_id}, default: []},
        scores: %{default: []}
      }
    },
    %{
      proto_file: "stacks/common/v1/writing_assistant.proto",
      proto_message: "UserBookContentAccess",
      table_name: "user_book_content_access",
      schema_prefix: "op",
      ecto_module: Stacks.WritingAssistant.UserBookContentAccess,
      ecto_path: "lib/stacks/gen/writing_assistant/user_book_content_access.ex",
      dbt_path: "stg_user_book_content_access.sql",
      timestamps: {:standard, updated_at: false},
      migration_exists: false,
      dbt_grant: true,
      indexes: [],
      field_overrides: %{
        user_id: %{
          belongs_to: Stacks.Accounts.User,
          references_table: :users,
          on_delete: :delete_all,
          null: false
        },
        book_id: %{
          belongs_to: Stacks.Books.Book,
          references_table: :books,
          on_delete: :delete_all,
          null: false
        },
        access_type: %{default: "granted", null: false},
        granted_at: %{ecto_type: :utc_datetime_usec}
      }
    },
    %{
      proto_file: "stacks/common/v1/writing_assistant.proto",
      proto_message: "Embedding",
      table_name: "embeddings",
      schema_prefix: "op",
      ecto_module: Stacks.WritingAssistant.Embedding,
      ecto_path: "lib/stacks/writing_assistant/embedding.ex",
      dbt_path: "stg_embeddings.sql",
      timestamps: :standard,
      migration_exists: true,
      skip_ecto: true,
      skip_dbt: true,
      indexes: [],
      field_overrides: %{
        user_id: %{
          belongs_to: Stacks.Accounts.User,
          references_table: :users,
          on_delete: :delete_all,
          null: false
        },
        source_type: %{null: false},
        source_id: %{ecto_type: :binary_id},
        content_date: %{ecto_type: :utc_datetime_usec}
      }
    },
    %{
      proto_file: "stacks/common/v1/writing_assistant.proto",
      proto_message: "BookContentChunk",
      table_name: "book_content_chunks",
      schema_prefix: "op",
      ecto_module: Stacks.WritingAssistant.BookContentChunk,
      ecto_path: "lib/stacks/writing_assistant/book_content_chunk.ex",
      dbt_path: "stg_book_content_chunks.sql",
      timestamps: :standard,
      migration_exists: true,
      skip_ecto: true,
      skip_dbt: true,
      indexes: [],
      field_overrides: %{
        book_id: %{
          belongs_to: Stacks.Books.Book,
          references_table: :books,
          on_delete: :delete_all,
          null: false
        },
        chunk_index: %{null: false},
        content: %{null: false}
      }
    }
  ],
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
        :pending_email_token,
        :pending_email_revert_token,
        :password_reset_token,
        :password_reset_sent_at,
        :failed_login_count,
        :failed_login_first_at,
        :locked_until,
        :lockout_duration_seconds
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
      skip_fields: [:associations, :author_display_name, :author_handle],
      field_overrides: %{}
    },
    %{
      proto_file: "stacks/common/v1/blog.proto",
      proto_message: "BookAssociation",
      function_name: :book_association,
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
