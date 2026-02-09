defmodule ThrottleWeb.Router do
  use ThrottleWeb, :router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :hubspot_verified do
    plug(ThrottleWeb.Plugs.HubSpotSignature)
  end

  scope "/api", ThrottleWeb do
    pipe_through([:api, :hubspot_verified])

    post("/hubspot/action", HubSpotController, :handle_action)
  end

  scope "/api", ThrottleWeb do
    pipe_through(:api)

    post("/config", ThrottleConfigController, :create)
    get("/config/:portal_id/:action_id", ThrottleConfigController, :show)

    # OAuth routes with names
    get("/oauth/authorize", OAuthController, :authorize, as: :oauth_authorize)
    get("/oauth/callback", OAuthController, :callback, as: :oauth_callback)
  end
end
