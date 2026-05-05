defmodule CoreWeb.Router do
  use CoreWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug StacksWeb.Plugs.SecurityHeaders
  end

  # Browser pipeline for the Elm SPA's HTML response. Only sets security
  # headers — the SPA route below is the catch-all that serves index.html
  # for client-side routing, so every page load runs through here and
  # picks up CSP, X-Frame-Options, HSTS, etc. Without this pipeline the
  # SPA's HTML response carries no security headers at all.
  pipeline :spa do
    plug StacksWeb.Plugs.SecurityHeaders
  end

  pipeline :authenticated do
    plug StacksWeb.Plugs.AuthPipeline
  end

  pipeline :optional_auth do
    plug StacksWeb.Plugs.OptionalAuthPipeline
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

  pipeline :rate_limit_public do
    plug StacksWeb.Plugs.RateLimiter, bucket: :public
  end

  pipeline :sse_auth do
    plug StacksWeb.Plugs.SSEAuthPipeline
  end

  # SSE endpoints must NOT use plug :accepts — EventSource sends
  # "Accept: text/event-stream" which Phoenix's MIME registry doesn't map
  # to the "event-stream" format name, causing spurious 406s.
  # The endpoint always returns text/event-stream so no negotiation is needed.
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
  end

  pipeline :rate_limit_admin do
    plug StacksWeb.Plugs.RateLimiter, bucket: :admin
  end

  pipeline :partner_auth do
    plug StacksWeb.PartnerAuthPlug
  end

  scope "/api", CoreWeb do
    pipe_through :api
    get "/health", HealthController, :index
  end

  # Public endpoints — no authentication required
  scope "/api", StacksWeb do
    pipe_through [:api, :rate_limit_public]
    get "/costs", CostController, :index
    post "/opt-out", OptOutController, :create
    post "/partners/register", PartnerRegistrationController, :create
  end

  # Authenticated listing routes — must be before optional_auth `:id` catch-all
  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated]
    get "/listings/mine", ListingController, :mine
  end

  # Public feeds — no auth required (Atom XML)
  scope "/api", StacksWeb do
    pipe_through [:api, :rate_limit_public]
    get "/feeds/:user_id/:bookshelf_name", FeedController, :show
  end

  # Public with optional auth — returns extra data when authenticated
  scope "/api", StacksWeb do
    pipe_through [:api, :optional_auth]
    get "/third-spaces", ThirdSpaceController, :index
    get "/books/:id/availability", BookAvailabilityController, :show
    get "/books/:id", BookController, :show
    get "/catalogue", CatalogueController, :index
    get "/listings", ListingController, :index
    get "/listings/:id", ListingController, :show
    get "/blog/posts", BlogController, :index
    get "/blog/posts/:id", BlogController, :show
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :rate_limit_auth]
    post "/auth/register", AuthController, :register
    post "/auth/login", AuthController, :login
    post "/auth/forgot-password", AuthController, :forgot_password
    post "/auth/reset-password", AuthController, :reset_password
  end

  scope "/api", StacksWeb do
    pipe_through :api
    get "/auth/confirm/:token", EmailVerificationController, :confirm
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated, :rate_limit_upload]
    post "/upload", UploadController, :create
    post "/upload/identify", UploadController, :identify
    # Presigned-URL upload flow — init issues the signed PUT, commit
    # verifies the client's direct-to-R2 upload + enqueues the job.
    post "/upload/init", UploadController, :init
    post "/upload/:image_id/commit", UploadController, :commit
  end

  scope "/api", StacksWeb do
    pipe_through [:sse_api, :sse_auth]
    get "/upload/:image_id/stream", UploadController, :stream
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated]

    delete "/auth/logout", AuthController, :logout
    get "/auth/me", AuthController, :me

    get "/books/isbn/:isbn", BookController, :show_by_isbn
    post "/books/confirm", BookController, :confirm
    post "/books/:id/merge-format", BookController, :merge_format
    resources "/books", BookController, only: [:create]

    get "/search", SearchController, :index

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

    get "/bookshelves/:bookshelf_name/shelves", ShelfController, :index
    post "/bookshelves/:bookshelf_name/shelves", ShelfController, :create
    delete "/shelves/:id", ShelfController, :delete
    put "/bookshelves/:bookshelf_name/shelves/reorder", ShelfController, :reorder

    get "/onboarding/status", OnboardingController, :status
    put "/onboarding/step/:step", OnboardingController, :complete_step
    post "/onboarding/reset", OnboardingController, :reset

    put "/settings/age_verification", UserSettingsController, :update_age_verification
    put "/settings/profile_visibility", UserSettingsController, :update_profile_visibility
    put "/settings/profile", UserSettingsController, :update_profile
    put "/settings/location", UserSettingsController, :update_location
    put "/settings/notifications", UserSettingsController, :update_notifications
    get "/settings/blocked-users", SocialController, :blocked_users

    put "/bookshelves/:id/visibility", BookshelfController, :update_visibility
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
    put "/blog/posts/:post_id/associations/:id/confirm", BlogController, :confirm_association
    put "/blog/posts/:post_id/associations/:id/dismiss", BlogController, :dismiss_association

    post "/gdpr/export", GDPRController, :export
    delete "/gdpr/account", GDPRController, :delete_account
    post "/gdpr/consent", GDPRController, :update_consent
  end

  # Content display routes — support ?view_as=<perspective> for preview
  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated, :view_as]
    get "/bookshelves/:bookshelf_name", BookshelfController, :show
  end

  # Password change — authenticated + stricter rate limit (3/min)
  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated, :rate_limit_password_change]
    put "/settings/password", UserSettingsController, :update_password
  end

  # Social actions — authenticated + per-user rate limit (20/min)
  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated, :rate_limit_social]
    post "/users/:id/block", SocialController, :block
    delete "/users/:id/block", SocialController, :unblock
  end

  # Metrics dashboard — owner role required
  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated, :require_owner]
    get "/metrics", MetricsController, :index
    get "/metrics/quality-trends", MetricsController, :quality_trends
    get "/metrics/source-health", MetricsController, :source_health
    get "/metrics/enrichment-gaps", MetricsController, :enrichment_gaps

    get "/admin/sources", SourceAdminController, :index
    put "/admin/sources/:id/approve", SourceAdminController, :approve
    put "/admin/sources/:id/reject", SourceAdminController, :reject

    get "/admin/partners", PartnerController, :index
    put "/admin/partners/:id/approve", PartnerController, :approve
    put "/admin/partners/:id/reject", PartnerController, :reject
  end

  # Partner API — authenticated via API key, no user auth
  scope "/api/partner", StacksWeb do
    pipe_through [:api, :partner_auth]

    post "/inventory", PartnerInventoryController, :sync
    post "/inventory/import", PartnerInventoryController, :import
    get "/inventory", PartnerInventoryController, :index

    post "/events", PartnerEventController, :create
    get "/events", PartnerEventController, :index
    delete "/events/:id", PartnerEventController, :delete
  end

  # Admin auth — public (no admin token needed)
  scope "/api/admin", StacksWeb do
    pipe_through [:api, :rate_limit_auth]
    post "/auth/login", AdminAuthController, :login
    post "/auth/verify_mfa", AdminAuthController, :verify_mfa
  end

  # Admin auth — requires valid admin session with MFA verified
  scope "/api/admin", StacksWeb do
    pipe_through [:api, :admin]
    delete "/auth/logout", AdminAuthController, :logout
  end

  # MFA enrollment — requires regular owner auth (no MFA yet)
  scope "/api/admin", StacksWeb do
    pipe_through [:api, :authenticated, :require_owner, :rate_limit_auth]
    post "/auth/mfa/setup", AdminAuthController, :mfa_setup
    post "/auth/mfa/confirm", AdminAuthController, :mfa_confirm
  end

  # Internal service-to-service callbacks — HMAC authenticated, no user auth
  scope "/api/internal", StacksWeb do
    pipe_through :api
    post "/vision/associate", InternalController, :vision_associate
    post "/smoke/circuit_breakers", InternalController, :smoke_circuit_breakers
  end

  # Catch-all: serve the Elm SPA for any non-API route (client-side routing)
  scope "/", CoreWeb do
    pipe_through :spa
    get "/*path", PageController, :index
  end
end
