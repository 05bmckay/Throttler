defmodule ThrottleWeb.Router do
  use ThrottleWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", ThrottleWeb do
    pipe_through :api

    post "/hubspot/action", HubSpotController, :handle_action
    post "/config", ThrottleConfigController, :create
    get "/config/:portal_id/:action_id", ThrottleConfigController, :show

    # OAuth routes with names
    get "/oauth/authorize", OAuthController, :authorize, as: :oauth_authorize
    get "/oauth/callback", OAuthController, :callback, as: :oauth_callback
  end
end
