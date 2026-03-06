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
    pipe_through [:api, :authenticated]

    delete "/auth/logout", AuthController, :logout
    get "/auth/me", AuthController, :me

    post "/upload", UploadController, :create

    get "/books/isbn/:isbn", BookController, :show_by_isbn
    resources "/books", BookController, only: [:show]

    get "/search", SearchController, :index

    get "/shelves/:shelf_name", ShelfController, :show

    post "/shelves/:shelf_name/placements", ShelfPlacementController, :create
    put "/placements/:id/move", ShelfPlacementController, :move
    delete "/placements/:id", ShelfPlacementController, :delete

    post "/gdpr/export", GDPRController, :export
    delete "/gdpr/account", GDPRController, :delete_account
    post "/gdpr/consent", GDPRController, :update_consent
  end
end
