defmodule CoreWeb.Router do
  use CoreWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
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

  pipeline :view_as do
    plug StacksWeb.Plugs.ViewAsPlug
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
  end

  # Public with optional auth — returns extra data when authenticated
  scope "/api", StacksWeb do
    pipe_through [:api, :optional_auth]
    get "/books/:id", BookController, :show
    get "/catalogue", CatalogueController, :index
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
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated]

    delete "/auth/logout", AuthController, :logout
    get "/auth/me", AuthController, :me

    get "/upload/:image_id/status", UploadController, :status

    get "/books/isbn/:isbn", BookController, :show_by_isbn
    post "/books/confirm", BookController, :confirm
    post "/books/:id/merge-format", BookController, :merge_format
    resources "/books", BookController, only: [:create]

    get "/search", SearchController, :index

    post "/bookshelves/:bookshelf_name/placements", BookshelfPlacementController, :create
    get "/placements/mine", BookshelfPlacementController, :mine
    put "/placements/:id/move", BookshelfPlacementController, :move
    put "/placements/:id/formats", BookshelfPlacementController, :update_formats
    delete "/placements/:id", BookshelfPlacementController, :delete

    put "/settings/age_verification", UserSettingsController, :update_age_verification
    put "/settings/profile_visibility", UserSettingsController, :update_profile_visibility
    put "/settings/profile", UserSettingsController, :update_profile
    put "/settings/location", UserSettingsController, :update_location
    put "/settings/notifications", UserSettingsController, :update_notifications
    get "/settings/blocked-users", SocialController, :blocked_users

    put "/bookshelves/:id/visibility", BookshelfController, :update_visibility
    put "/placements/:id/visibility", BookshelfPlacementController, :update_visibility

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

  # Internal service-to-service callbacks — HMAC authenticated, no user auth
  scope "/api/internal", StacksWeb do
    pipe_through :api
    post "/vision/associate", InternalController, :vision_associate
  end

  # Catch-all: serve the Elm SPA for any non-API route (client-side routing)
  scope "/", CoreWeb do
    get "/*path", PageController, :index
  end
end
