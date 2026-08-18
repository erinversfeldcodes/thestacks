defmodule CoreWeb.Router do
  use CoreWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug StacksWeb.Plugs.SecurityHeaders
  end

  pipeline :spa do
    plug StacksWeb.Plugs.SecurityHeaders
  end

  pipeline :authenticated do
    plug StacksWeb.Plugs.AuthPipeline
  end

  pipeline :optional_auth do
    plug StacksWeb.Plugs.OptionalAuthPipeline
  end

  pipeline :writing_assistant_consent do
    plug StacksWeb.Plugs.ConsentCheck, feature: "writing_assistant"
  end

  pipeline :rate_limit_auth do
    plug StacksWeb.Plugs.RateLimiter, bucket: :auth
  end

  pipeline :rate_limit_upload do
    plug StacksWeb.Plugs.RateLimiter, bucket: :upload
  end

  pipeline :rate_limit_password_change do
    plug StacksWeb.Plugs.RateLimiter, bucket: :password_change
  end

  pipeline :rate_limit_social do
    plug StacksWeb.Plugs.RateLimiter, bucket: :social
  end

  pipeline :rate_limit_feedback do
    plug StacksWeb.Plugs.RateLimiter, bucket: :feedback
  end

  pipeline :rate_limit_public do
    plug StacksWeb.Plugs.RateLimiter, bucket: :public
  end

  pipeline :sse_auth do
    plug StacksWeb.Plugs.SSEAuthPipeline
  end

  pipeline :sse_api do
    plug StacksWeb.Plugs.SecurityHeaders
  end

  pipeline :view_as do
    plug StacksWeb.Plugs.ViewAsPlug
  end

  pipeline :require_owner do
    plug StacksWeb.Plugs.RequireRole, role: "owner"
  end

  pipeline :admin do
    plug StacksWeb.Plugs.AdminAuthPipeline
    plug StacksWeb.Plugs.RequireMFA
    plug StacksWeb.Plugs.AuditAdminCall
  end

  pipeline :rate_limit_admin do
    plug StacksWeb.Plugs.RateLimiter, bucket: :admin
  end

  pipeline :rate_limit_e2e_helper do
    plug StacksWeb.Plugs.RateLimiter, bucket: :e2e_helper
  end

  pipeline :partner_auth do
    plug StacksWeb.PartnerAuthPlug
  end

  scope "/api", CoreWeb do
    pipe_through :api
    get "/health", HealthController, :index
    get "/health/ready", HealthController, :ready
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :rate_limit_public]
    get "/config", ConfigController, :show
    get "/costs", CostController, :index
    get "/transparency/metrics", TransparencyController, :index
    get "/authors/:id/events", AuthorEventsController, :index
    post "/opt-out", OptOutController, :create
    post "/partners/register", PartnerRegistrationController, :create
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated]
    get "/listings/mine", ListingController, :mine
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :rate_limit_public]
    get "/feeds/u/:handle/blog", BlogFeedController, :show
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :optional_auth, :rate_limit_public]
    get "/feeds/u/:handle/:bookshelf_name", FeedController, :show
    get "/feeds/:user_id/:bookshelf_name", FeedController, :show
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :optional_auth]
    get "/third-spaces", ThirdSpaceController, :index
    get "/books/:id/availability", BookAvailabilityController, :show
    get "/books/:id/prices", BookPriceController, :show
    get "/books/:id", BookController, :show
    get "/catalogue", CatalogueController, :index
    get "/listings", ListingController, :index
    get "/listings/:id", ListingController, :show
    get "/blog/posts", BlogController, :index
    get "/blog/posts/:id", BlogController, :show
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :optional_auth, :rate_limit_public]
    get "/search/users", UserSearchController, :index
    get "/u/:handle", ProfileController, :show
    get "/u/:handle/bookshelves/:bookshelf_name", ProfileController, :shelf
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :rate_limit_auth]
    post "/auth/register", AuthController, :register
    post "/auth/login", AuthController, :login
    post "/auth/forgot-password", AuthController, :forgot_password
    post "/auth/reset-password", AuthController, :reset_password
    post "/auth/resend-confirmation", AuthController, :resend_confirmation
  end

  scope "/api", StacksWeb do
    pipe_through :api
    get "/auth/confirm/:token", EmailVerificationController, :confirm
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated, :rate_limit_upload]
    post "/upload/init", UploadController, :init
    post "/upload/:image_id/commit", UploadController, :commit

    post "/upload/:image_id/reject-identification",
         UploadController,
         :reject_identification
  end

  scope "/api", StacksWeb do
    pipe_through :api
    put "/upload/:image_id/data", UploadController, :upload_data
  end

  scope "/api", StacksWeb do
    pipe_through [:sse_api, :sse_auth]
    get "/upload/:image_id/stream", UploadController, :stream
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated]

    get "/uploads/inbox", UploadController, :inbox

    delete "/auth/logout", AuthController, :logout
    post "/auth/refresh", AuthController, :refresh
    get "/auth/me", AuthController, :me

    get "/books/isbn/:isbn", BookController, :show_by_isbn
    post "/books/confirm", BookController, :confirm
    post "/books/:id/merge-format", BookController, :merge_format
    put "/books/:id/age-gate", BookController, :set_age_gate
    resources "/books", BookController, only: [:create]

    get "/search", SearchController, :index

    post "/imports/goodreads", ImportController, :create
    get "/imports", ImportController, :index
    get "/imports/:id", ImportController, :show
    get "/imports/:id/rows", ImportController, :rows

    post "/listings", ListingController, :create
    put "/listings/:id/activate", ListingController, :activate
    put "/listings/:id/deactivate", ListingController, :deactivate
    put "/listings/:id/sold", ListingController, :sold

    post "/bookshelves/:bookshelf_name/placements", BookshelfPlacementController, :create
    get "/placements/mine", BookshelfPlacementController, :mine
    put "/placements/:id/move", BookshelfPlacementController, :move
    put "/placements/:id/formats", BookshelfPlacementController, :update_formats
    put "/placements/:id/progress", BookshelfPlacementController, :update_progress
    put "/placements/:id/shelf", BookshelfPlacementController, :move_to_shelf
    delete "/placements/:id", BookshelfPlacementController, :delete
    post "/placements/:id/restore", BookshelfPlacementController, :restore

    get "/bookshelves/:bookshelf_name/shelves", ShelfController, :index
    post "/bookshelves/:bookshelf_name/shelves", ShelfController, :create
    delete "/shelves/:id", ShelfController, :delete
    put "/bookshelves/:bookshelf_name/shelves/reorder", ShelfController, :reorder

    get "/onboarding/status", OnboardingController, :status
    put "/onboarding/step/:step", OnboardingController, :complete_step
    post "/onboarding/reset", OnboardingController, :reset

    get "/me/inferences", MeInferenceController, :index

    get "/settings/privacy", UserSettingsController, :show_privacy
    put "/settings/profile_visibility", UserSettingsController, :update_profile_visibility
    put "/settings/profile", UserSettingsController, :update_profile
    put "/settings/location", UserSettingsController, :update_location
    get "/settings/notifications", UserSettingsController, :show_notifications
    put "/settings/notifications", UserSettingsController, :update_notifications
    get "/settings/blocked-users", SocialController, :blocked_users
    get "/settings/audit-log", AuditLogController, :index

    put "/bookshelves/:bookshelf_name/visibility", BookshelfController, :update_visibility
    put "/placements/:id/visibility", BookshelfPlacementController, :update_visibility

    get "/posts/:post_id/comments", CommentController, :index
    post "/posts/:post_id/comments", CommentController, :create
    delete "/comments/:id", CommentController, :delete

    post "/bookshelves/:bookshelf_id/grants", VisibilityGrantController, :create
    get "/bookshelves/:bookshelf_id/grants", VisibilityGrantController, :index
    delete "/bookshelves/:bookshelf_id/grants/:user_id", VisibilityGrantController, :delete

    post "/groups", GroupController, :create
    get "/groups/:id", GroupController, :show
    get "/groups/:id/feed", GroupFeedController, :index

    post "/groups/:group_id/invitations", GroupMemberController, :invite
    post "/groups/:group_id/invitations/:id/accept", GroupMemberController, :accept
    post "/groups/:group_id/invitations/:id/decline", GroupMemberController, :decline
    delete "/groups/:group_id/members/:user_id", GroupMemberController, :remove
    delete "/groups/:group_id/leave", GroupMemberController, :leave

    post "/blog/posts", BlogController, :create
    put "/blog/posts/:id", BlogController, :update
    delete "/blog/posts/:id", BlogController, :delete
    post "/blog/posts/:id/publish", BlogController, :publish
    get "/blog/posts/:id/syndication", BlogController, :syndication
    post "/blog/posts/:id/syndications", BlogController, :create_syndication
    put "/blog/posts/:id/syndications/:sid", BlogController, :update_syndication
    put "/blog/posts/:post_id/associations/:id/confirm", BlogController, :confirm_association
    put "/blog/posts/:post_id/associations/:id/dismiss", BlogController, :dismiss_association

    post "/gdpr/export", GDPRController, :export
    delete "/gdpr/account", GDPRController, :delete_account
    post "/gdpr/consent", GDPRController, :update_consent
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated, :writing_assistant_consent]
    post "/blog/posts/:id/chat", BlogController, :chat
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated, :view_as]
    get "/bookshelves/:bookshelf_name", BookshelfController, :show
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated, :rate_limit_password_change]
    put "/settings/password", UserSettingsController, :update_password
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated, :rate_limit_social]
    post "/users/:id/block", SocialController, :block
    delete "/users/:id/block", SocialController, :unblock
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated, :rate_limit_feedback]
    post "/feedback", FeedbackController, :create
  end

  scope "/api/admin", StacksWeb do
    pipe_through [:api, :admin, :rate_limit_admin]
    get "/sources", SourceAdminController, :index
    put "/sources/:id/approve", SourceAdminController, :approve
    put "/sources/:id/reject", SourceAdminController, :reject
    get "/removal-requests", SourceAdminController, :removal_requests
    put "/removal-requests/:id/honour", SourceAdminController, :honour_removal
    put "/removal-requests/:id/decline", SourceAdminController, :decline_removal
    get "/source-health", SourceAdminController, :source_health

    get "/books", BookModerationController, :index
    put "/books/:id/age-gate", BookModerationController, :set_age_gate

    get "/partners", PartnerController, :index
    put "/partners/:id/approve", PartnerController, :approve
    put "/partners/:id/reject", PartnerController, :reject

    get "/feedback", FeedbackAdminController, :index
  end

  scope "/api/partner", StacksWeb do
    pipe_through [:api, :partner_auth]

    post "/inventory", PartnerInventoryController, :sync
    post "/inventory/import", PartnerInventoryController, :import
    get "/inventory", PartnerInventoryController, :index

    post "/events", PartnerEventController, :create
    get "/events", PartnerEventController, :index
    delete "/events/:id", PartnerEventController, :delete
  end

  scope "/api/admin", StacksWeb do
    pipe_through [:api, :rate_limit_auth]
    post "/auth/login", AdminAuthController, :login
    post "/auth/verify_mfa", AdminAuthController, :verify_mfa
  end

  scope "/api/auth", StacksWeb do
    pipe_through [:api, :rate_limit_auth]
    get "/invite/:code", InviteController, :show
  end

  scope "/api/admin", StacksWeb do
    pipe_through [:api, :admin, :require_owner, :rate_limit_admin]
    get "/invites", InviteAdminController, :index
    post "/invites", InviteAdminController, :create
    delete "/invites/:id", InviteAdminController, :delete
  end

  scope "/api/admin", StacksWeb do
    pipe_through [:api, :admin]
    delete "/auth/logout", AdminAuthController, :logout
  end

  scope "/api/admin", StacksWeb do
    pipe_through [:api, :authenticated, :require_owner, :rate_limit_auth]
    post "/auth/mfa/setup", AdminAuthController, :mfa_setup
    post "/auth/mfa/confirm", AdminAuthController, :mfa_confirm
  end

  scope "/api/admin", StacksWeb do
    pipe_through [:api, :admin, :rate_limit_admin]
    get "/users/by_email", AdminController, :by_email
    get "/users/by_id", AdminController, :by_id
    get "/audit_log", AdminController, :audit_log
    get "/platform_stats", AdminController, :platform_stats
    get "/gdpr_export", AdminController, :gdpr_export
    post "/gdpr_erase", AdminController, :gdpr_erase
  end

  scope "/api/admin", StacksWeb do
    pipe_through [:api, :admin, :require_owner, :rate_limit_admin]
    get "/data_corrections", DataCorrectionController, :index
    post "/data_corrections/:name/apply", DataCorrectionController, :apply
    post "/data_corrections/:name/target", DataCorrectionController, :target
  end

  scope "/api/internal", StacksWeb do
    pipe_through :api
    post "/vision/associate", InternalController, :vision_associate
    post "/smoke/circuit_breakers", InternalController, :smoke_circuit_breakers
  end

  scope "/api/test", StacksWeb do
    pipe_through [:api, StacksWeb.Plugs.E2ETestHelper, :rate_limit_e2e_helper]
    get "/confirmation-token", TestHelperController, :confirmation_token
    get "/sent-emails", TestHelperController, :sent_emails
    put "/age-verification", TestHelperController, :set_age_verification
    post "/session", TestHelperController, :mint_session
    post "/book-writing", TestHelperController, :seed_book_writing
    post "/book-description", TestHelperController, :seed_book_description
  end

  scope "/", CoreWeb do
    pipe_through :spa

    get "/settings/consent", PageController, :redirect_consent

    get "/*path", PageController, :index
  end
end
