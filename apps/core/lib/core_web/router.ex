defmodule CoreWeb.Router do
  use CoreWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug StacksWeb.Plugs.SecurityHeaders
  end

  pipeline :authenticated do
    plug StacksWeb.Plugs.AuthPipeline
  end

  pipeline :rate_limit_auth do
    plug StacksWeb.Plugs.RateLimiter, bucket: :auth
  end

  pipeline :rate_limit_upload do
    plug StacksWeb.Plugs.RateLimiter, bucket: :upload
  end

  scope "/api", CoreWeb do
    pipe_through :api
    get "/health", HealthController, :index
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :rate_limit_auth]
    post "/auth/register", AuthController, :register
    post "/auth/login", AuthController, :login
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated, :rate_limit_upload]
    post "/upload", UploadController, :create
  end

  scope "/api", StacksWeb do
    pipe_through [:api, :authenticated]

    delete "/auth/logout", AuthController, :logout
    get "/auth/me", AuthController, :me

    get "/upload/:image_id/status", UploadController, :status

    get "/books/isbn/:isbn", BookController, :show_by_isbn
    resources "/books", BookController, only: [:show, :create]

    get "/search", SearchController, :index

    get "/bookshelves/:bookshelf_name", BookshelfController, :show

    post "/bookshelves/:bookshelf_name/placements", BookshelfPlacementController, :create
    put "/placements/:id/move", BookshelfPlacementController, :move
    put "/placements/:id/formats", BookshelfPlacementController, :update_formats
    delete "/placements/:id", BookshelfPlacementController, :delete

    put "/settings/age_verification", UserSettingsController, :update_age_verification

    post "/gdpr/export", GDPRController, :export
    delete "/gdpr/account", GDPRController, :delete_account
    post "/gdpr/consent", GDPRController, :update_consent
  end
end
