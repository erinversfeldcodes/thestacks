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

  # Gates a route behind writing-assistant consent (Issue #184). Halts with 403
  # when the current user has not granted `consent_writing_assistant`. Runs after
  # :authenticated so a current resource is present.
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
  end

  # Public endpoints — no authentication required
  scope "/api", StacksWeb do
    pipe_through [:api, :rate_limit_public]
    # Frontend runtime feature-flag config (ADR-020). Unauthenticated; the
    # payload is a flat map of booleans only (no user/partner data).
    get "/config", ConfigController, :show
    get "/costs", CostController, :index
    # Public transparency metrics (#241 / ADR-019) — curated, anonymised subset
    # of observability. No auth; the whitelist + mart columns ARE the privacy
    # boundary. Rate-limited via :rate_limit_public.
    get "/transparency/metrics", TransparencyController, :index
    post "/opt-out", OptOutController, :create
    post "/partners/register", PartnerRegistrationController, :create
  end

  # Authenticated listing routes — must be before optional_auth `:id` catch-all
  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated]
    get "/listings/mine", ListingController, :mine
  end

  # Feeds (Atom XML). `:optional_auth` because eligibility is not uniform: a `public` bookshelf
  # is served to anyone, a `platform` one only to a signed-in reader — `platform` means "any
  # authenticated platform user, NOT visible to logged-out" on the Audience ladder, so serving it
  # anonymously would have contradicted the ladder's own definition. Owner decision 2026-07-29.
  scope "/api", StacksWeb do
    pipe_through [:api, :optional_auth, :rate_limit_public]
    # Handle-addressed and canonical: a page showing someone's bookshelves knows their
    # handle, not their UUID, which is why no client could build a feed URL before.
    # Declared first so "u" is not swallowed as a :user_id.
    get "/feeds/u/:handle/:bookshelf_name", FeedController, :show
    # Retained for any direct link already in a reader.
    get "/feeds/:user_id/:bookshelf_name", FeedController, :show
  end

  # Public with optional auth — returns extra data when authenticated
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

  # Public profile + people-search reads (#210). Same optional-auth model as the
  # scope above, but additionally rate-limited (:rate_limit_public): these are the
  # highest-value unauthenticated enumeration surfaces — /search/users is a
  # directory-scraper vector and /u/:handle a handle-existence oracle.
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
    # Same bucket as its siblings on purpose (#373): the `:auth` limiter is
    # per-IP and is consumed before the action runs, so a caller probing
    # addresses here is throttled at exactly the rate a reader retrying their
    # own is. A per-account limit would have re-opened the enumeration channel
    # the uniform response closes.
    post "/auth/resend-confirmation", AuthController, :resend_confirmation
  end

  scope "/api", StacksWeb do
    pipe_through :api
    get "/auth/confirm/:token", EmailVerificationController, :confirm
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated, :rate_limit_upload]
    # Presigned-URL upload flow — init issues the signed PUT, commit
    # verifies the client's direct-to-R2 upload + enqueues the job.
    post "/upload/init", UploadController, :init
    post "/upload/:image_id/commit", UploadController, :commit
    # Rejection-retry — user clicks "No, try again" on an identified
    # book. Backend stays stateless w.r.t. the rejection list: the
    # frontend supplies the cumulative list of rejected book IDs and
    # we enqueue a fresh IdentifyBookJob with the list forwarded to
    # the vision model as exclusions.
    post "/upload/:image_id/reject-identification",
         UploadController,
         :reject_identification
  end

  # Upload data PUT — no user auth. The image_id UUID (128-bit random) is the
  # effective auth token: anyone who can guess it can PUT data, but commit_upload
  # verifies ownership before enqueuing vision work. Proxying through Phoenix
  # (same origin as the SPA) avoids R2 CORS preflight failures when the browser
  # origin (*.fly.dev, localhost) is not in the R2 bucket's CORS allowlist.
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

    # The upload inbox (#351) — read-only, and deliberately NOT in the
    # `:upload` rate-limit bucket its siblings above sit in. That bucket exists
    # to price GPU work; this is a list query the navigation badge issues on
    # every page load, and throttling it would blank the badge rather than
    # protect anything.
    get "/uploads/inbox", UploadController, :inbox

    delete "/auth/logout", AuthController, :logout
    post "/auth/refresh", AuthController, :refresh
    get "/auth/me", AuthController, :me

    get "/books/isbn/:isbn", BookController, :show_by_isbn
    post "/books/confirm", BookController, :confirm
    post "/books/:id/merge-format", BookController, :merge_format
    # User-side age gate: the person who added a book marks it "adults only".
    # Raise-only (public → age_gated); lowering is owner-only (403). #118.
    put "/books/:id/age-gate", BookController, :set_age_gate
    resources "/books", BookController, only: [:create]

    get "/search", SearchController, :index

    # Goodreads library import (US-1.1.9). Synchronous parse, async shelving.
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
    put "/blog/posts/:post_id/associations/:id/confirm", BlogController, :confirm_association
    put "/blog/posts/:post_id/associations/:id/dismiss", BlogController, :dismiss_association

    post "/gdpr/export", GDPRController, :export
    delete "/gdpr/account", GDPRController, :delete_account
    post "/gdpr/consent", GDPRController, :update_consent
  end

  # Writing-assistant chat (Issue #184) — authenticated + gated by
  # writing_assistant consent. A user without consent gets 403 at the pipeline;
  # with consent, the action returns an honest "under construction" response.
  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated, :writing_assistant_consent]
    post "/blog/posts/:id/chat", BlogController, :chat
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

  # Source and partner admin — MFA-verified admin session required
  scope "/api/admin", StacksWeb do
    pipe_through [:api, :admin, :rate_limit_admin]
    get "/sources", SourceAdminController, :index
    put "/sources/:id/approve", SourceAdminController, :approve
    put "/sources/:id/reject", SourceAdminController, :reject
    # Removal-request review (US-2.5.3). Verbs name what happens to the LISTING, because
    # `/sources/:id/approve` above already means "publish it" — the opposite effect.
    get "/removal-requests", SourceAdminController, :removal_requests
    put "/removal-requests/:id/honour", SourceAdminController, :honour_removal
    put "/removal-requests/:id/decline", SourceAdminController, :decline_removal
    get "/source-health", SourceAdminController, :source_health

    # Owner age-gate moderation (#118): list all books (incl. age-gated) and
    # override a book's visibility tier in EITHER direction.
    get "/books", BookModerationController, :index
    put "/books/:id/age-gate", BookModerationController, :set_age_gate

    get "/partners", PartnerController, :index
    put "/partners/:id/approve", PartnerController, :approve
    put "/partners/:id/reject", PartnerController, :reject
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

  # Invitation lookup (US-14.1.3) — public, but on the shared :auth rate bucket:
  # a code-guessing sweep and a password-guessing sweep are the same attack
  # against the same door (#373), so they share one budget.
  scope "/api/auth", StacksWeb do
    pipe_through [:api, :rate_limit_auth]
    get "/invite/:code", InviteController, :show
  end

  # Invitation issue/revoke (US-14.1.3) — the owner widens the beta, nobody
  # else. `:require_owner` on top of `:admin` for the same stale-token reason
  # as the data-correction routes (#340).
  scope "/api/admin", StacksWeb do
    pipe_through [:api, :admin, :require_owner, :rate_limit_admin]
    get "/invites", InviteAdminController, :index
    post "/invites", InviteAdminController, :create
    delete "/invites/:id", InviteAdminController, :delete
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

  # Admin data endpoints — requires valid admin session with MFA verified + audit logging
  scope "/api/admin", StacksWeb do
    pipe_through [:api, :admin, :rate_limit_admin]
    get "/users/by_email", AdminController, :by_email
    get "/users/by_id", AdminController, :by_id
    get "/audit_log", AdminController, :audit_log
    get "/platform_stats", AdminController, :platform_stats
    get "/gdpr_export", AdminController, :gdpr_export
    post "/gdpr_erase", AdminController, :gdpr_erase
  end

  # Owner-facilitated data correction (#340). `:require_owner` sits on top of
  # `:admin` deliberately: these two routes rewrite production rows, and an
  # admin token outlives the role it was minted under, so the role is re-checked
  # where the write happens rather than only at login.
  scope "/api/admin", StacksWeb do
    pipe_through [:api, :admin, :require_owner, :rate_limit_admin]
    get "/data_corrections", DataCorrectionController, :index
    post "/data_corrections/:name/apply", DataCorrectionController, :apply
    # Targeted corrections (#376) — a POST even to dry-run, because a correction
    # that takes an argument has nothing to report without a body.
    post "/data_corrections/:name/target", DataCorrectionController, :target
  end

  # Internal service-to-service callbacks — HMAC authenticated, no user auth
  scope "/api/internal", StacksWeb do
    pipe_through :api
    post "/vision/associate", InternalController, :vision_associate
    post "/smoke/circuit_breakers", InternalController, :smoke_circuit_breakers
  end

  # Test-only helper endpoints (Issue #124). Unauthenticated by design — the
  # E2E suite calls these before it has a session. The E2ETestHelper plug is
  # the sole gate: it returns 404 for every request unless the server flag
  # STACKS_E2E_TEST_HELPERS=1 is set, which production never sets. This is why
  # the guard lives in the router pipeline (fails closed) rather than in the
  # controller. The endpoint leaks an account-activation token, so a real 404
  # (not the SPA catch-all's index.html) is returned when the flag is off.
  #
  # PE-gate hardening (Issue #124): on public preview apps the flag IS on, so
  # (1) the controller scopes lookups to `@thestacks.test` accounts only — a
  # real user's token can never resolve — and (2) the `:e2e_helper` rate-limit
  # bucket (10/min per IP) bounds brute-force enumeration / token harvesting.
  scope "/api/test", StacksWeb do
    pipe_through [:api, StacksWeb.Plugs.E2ETestHelper, :rate_limit_e2e_helper]
    get "/confirmation-token", TestHelperController, :confirmation_token
    get "/sent-emails", TestHelperController, :sent_emails
    put "/age-verification", TestHelperController, :set_age_verification
    # Mints a confirmed `.test`-domain user + session token in one call so E2E
    # specs skip the :auth-bucket register/login dance (Issue #192). Hard
    # `.test`-domain allowlist in the controller — never mints a real account.
    post "/session", TestHelperController, :mint_session
    # Seeds a visible blog-post→book association for a `.test`-domain user so the
    # spine bookmark-ribbon spec (#287) is deterministic (prod associates via an
    # async LLM worker). Same hard `.test`-domain allowlist in the controller.
    post "/book-writing", TestHelperController, :seed_book_writing
    # Inserts a fresh public book carrying a description so the #284 deep-search
    # spec can drive a live description match + snippet (the seed has 0
    # description-bearing books). Catalogue metadata only — no user data/PII.
    post "/book-description", TestHelperController, :seed_book_description
  end

  # Catch-all: serve the Elm SPA for any non-API route (client-side routing)
  scope "/", CoreWeb do
    pipe_through :spa

    # Consent folded into Privacy (#318 TR-4). The former /settings/consent page
    # is gone; a 302 keeps existing links and bookmarks working by sending the
    # browser to the Privacy page (which now hosts the consent controls). Must
    # sit BEFORE the catch-all, or the SPA index would swallow it.
    get "/settings/consent", PageController, :redirect_consent

    get "/*path", PageController, :index
  end
end
