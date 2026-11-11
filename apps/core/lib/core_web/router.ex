defmodule CoreWeb.Router do
  use CoreWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug StacksWeb.Plugs.SecurityHeaders

    # ⚠️ COUNTS, and cannot reject. Shipped before any enforcement so the
    # decision to enforce is a reading of present/absent/mismatched over real
    # traffic rather than a judgement — the recorded failure behind this work is
    # an enforcement switched on before the client side was converted.
    #
    # On `:api` rather than on each authenticated pipeline, so the pre-auth
    # writes (login, password reset, registration) are counted too: they are
    # state-changing and they are exactly the routes a token issued at login
    # would have missed.
    plug StacksWeb.Plugs.CsrfCounter

    # ⛔ REFUSES, and it runs AFTER the counter so a rejected request is counted
    # before it is turned away — otherwise enforcement would hide the very
    # signal that says whether enforcement is correct.
    plug StacksWeb.Plugs.CsrfEnforce
  end

  pipeline :spa do
    plug StacksWeb.Plugs.SecurityHeaders

    # ⚠️ The CSRF cookie is issued HERE, on the SPA's own HTML response, rather
    # than at login. A browser cannot send any XHR — the login POST included —
    # before it has loaded this page, so every later request carries a token
    # with no exemption and no assumption about what the client does at boot.
    plug StacksWeb.Plugs.CsrfCookie
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

  pipeline :rate_limit_feedback do
    plug StacksWeb.Plugs.RateLimiter, bucket: :feedback
  end

  pipeline :rate_limit_public do
    plug StacksWeb.Plugs.RateLimiter, bucket: :public
  end

  # ⚠️ Not `:api`, and the reason is the COUNTER rather than the scope gate.
  #
  # ⛔ The first version of this comment said keeping the stream out "leaves the
  # counter's declared scope exactly the set of state-changing routes it says it
  # covers" — which is not a reason, because `scripts/check-csrf-scope.sh`
  # parses only `post|put|patch|delete`. A GET was never in its population, so
  # joining `:api` could not have moved its numbers either way.
  #
  # ⚖️ The real reason: `CsrfCounter` counts safe methods as `:safe` rather than
  # skipping them (`@safe_methods ~w(GET HEAD OPTIONS)`). Putting the upload
  # stream on `:api` would pour every one of its requests into that series —
  # and the series is how the rollout decides whether the CSRF proof is
  # arriving. A long-lived SSE connection is structurally incapable of needing a
  # proof, so counting it is noise in the one reading that has to stay clean.
  #
  # ⚠️ Stated at this length because the wrong version was ACTIONABLE: a reader
  # could "fix the inconsistency" by joining `:api`, see the scope gate
  # unchanged exactly as the old comment promised, and conclude it was safe.
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
    # ⛔ THE ORDINARY SESSION FIRST, and this line is the whole point of the
    # change that introduced it. `AdminAuthPipeline` used to authenticate from a
    # SECOND Guardian token the SPA held in memory, so a reload dropped the
    # elevation and re-prompted for MFA that the server had already recorded.
    # Now the operator is identified exactly as on every other authenticated
    # route — the HttpOnly cookie — and their admin session is looked up from
    # that user.
    #
    # ⚠️ Here rather than added to each route's `pipe_through`, so the pipeline
    # states its own prerequisite: an admin route that reached
    # `AdminAuthPipeline` without an authenticated reader would 401 on every
    # request, which is a confusing way to learn about a missing plug.
    plug StacksWeb.Plugs.AuthPipeline
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

  # Anonymous reads, metered. This scope carried no rate limiter while every
  # sibling public scope had one, so the catalogue, the listings and the blog
  # archive were the endpoints anyone could poll without limit — the heaviest
  # of them by a distance. Guarded by scripts/check-public-route-metering.sh.
  scope "/api", StacksWeb do
    pipe_through [:api, :optional_auth, :rate_limit_public]
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
    get "/search", SearchController, :index
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
    get "/auth/confirm-email-change/:token", EmailVerificationController, :confirm_change
    get "/auth/revert-email-change/:token", EmailVerificationController, :revert_change
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
    # ⛔ AUTHENTICATED AND RATE-LIMITED, like the two endpoints that bracket it.
    #
    # This scope carried `:api` alone, so the one route that accepts 20 MB of
    # bytes was the only part of the upload flow with neither. MEASURED on a
    # deployed stack: a `PUT` with no `Authorization` header, an `image_id` that
    # is not a UUID and was never reserved, and 20,361 bytes of JPEG returned
    # **200**.
    #
    # ⚠️ The CSRF proof in front of it was never the missing control. It
    # establishes that a request came from a document on our origin, which any
    # browser and any scripted client can arrange; it says nothing about WHO is
    # asking or WHAT they may write to.
    pipe_through [:api, :authenticated, :rate_limit_upload]
    put "/upload/:image_id/data", UploadController, :upload_data
  end

  scope "/api", StacksWeb do
    # ⛔ `:authenticated`, the same pipeline every other authenticated route
    # uses. There used to be a bespoke `:sse_auth` here reading the token from
    # `?token=`, because `EventSource` cannot set an `Authorization` header —
    # which put a live credential in request logs, in `Referer` and in browser
    # history. `EventSource` DOES send cookies on a same-origin request, and
    # every request this SPA makes is same-origin (`Api.baseUrl` is `""`), so
    # the session travels the way it does everywhere else and the second
    # authentication path is gone.
    pipe_through [:sse_api, :authenticated]
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
    get "/groups/:group_id/members", GroupMemberController, :index
    delete "/groups/:group_id/members/:user_id", GroupMemberController, :remove
    delete "/groups/:group_id/leave", GroupMemberController, :leave

    post "/blog/posts", BlogController, :create
    put "/blog/posts/:id", BlogController, :update
    delete "/blog/posts/:id", BlogController, :delete
    post "/blog/posts/:id/publish", BlogController, :publish
    get "/blog/posts/:id/syndication", BlogController, :syndication
    get "/blog/posts/:id/syndications", BlogController, :list_syndications
    post "/blog/posts/:id/syndications", BlogController, :create_syndication
    put "/blog/posts/:id/syndications/:sid", BlogController, :update_syndication
    put "/blog/posts/:post_id/associations/:id/confirm", BlogController, :confirm_association
    put "/blog/posts/:post_id/associations/:id/dismiss", BlogController, :dismiss_association

    post "/gdpr/export", GDPRController, :export
    delete "/gdpr/account", GDPRController, :delete_account
    post "/gdpr/consent", GDPRController, :update_consent
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
    post "/invite/check", InviteController, :check
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
    get "/degraded_accounts", AdminController, :degraded_accounts
    post "/degraded_accounts/restore", AdminController, :restore_degraded_account
  end

  scope "/api/admin", StacksWeb do
    pipe_through [:api, :admin, :require_owner, :rate_limit_admin]
    get "/data_corrections", DataCorrectionController, :index
    post "/data_corrections/:name/apply", DataCorrectionController, :apply
    post "/data_corrections/:name/target", DataCorrectionController, :target
  end

  scope "/api/internal", StacksWeb do
    pipe_through :api
    post "/smoke/circuit_breakers", InternalController, :smoke_circuit_breakers
  end

  scope "/api/test", StacksWeb do
    pipe_through [:api, StacksWeb.Plugs.E2ETestHelper, :rate_limit_e2e_helper]
    get "/confirmation-token", TestHelperController, :confirmation_token
    get "/sent-emails", TestHelperController, :sent_emails
    get "/email-budget", TestHelperController, :email_budget
    put "/age-verification", TestHelperController, :set_age_verification
    delete "/admin-sessions", TestHelperController, :revoke_admin_sessions
    post "/session", TestHelperController, :mint_session
    post "/book-writing", TestHelperController, :seed_book_writing
    post "/book-description", TestHelperController, :seed_book_description
    post "/association-outcome", TestHelperController, :seed_association_outcome
  end

  # ⛔ Must stay ABOVE the SPA catch-all. Everything under `/api` that no route
  # above matched is an API request that does not exist, and it has to say so in
  # the API's own vocabulary. Falling through to the catch-all made every such
  # request answer `200 text/html` with the app shell, which meant a removed or
  # mistyped endpoint was indistinguishable from a working one by status, and
  # `Api.isNotFound` could never fire for it.
  scope "/api", CoreWeb do
    pipe_through :api

    match :*, "/*path", PageController, :api_not_found
  end

  scope "/", CoreWeb do
    pipe_through :spa

    get "/settings/consent", PageController, :redirect_consent

    get "/*path", PageController, :index
  end
end
