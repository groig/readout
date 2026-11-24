defmodule ReadoutWeb.Router do
  use ReadoutWeb, :router

  import ReadoutWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ReadoutWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"referrer-policy" => "strict-origin-when-cross-origin"}
    plug ReadoutWeb.Plugs.ContentSecurityPolicy
    plug :fetch_current_scope_for_user
    plug ReadoutWeb.Locale
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ReadoutWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  ## The team app (signed in)
  #
  # Every app LiveView lives in this live_session: it requires a signed-in,
  # active user, then resolves locale/time zone and attaches shell events.
  # Pages gated on a role add `on_mount {ReadoutWeb.UserAuth, {:can, action}}`.

  scope "/", ReadoutWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [
        {ReadoutWeb.UserAuth, :require_authenticated},
        ReadoutWeb.Locale,
        ReadoutWeb.Shell
      ] do
      live "/documents", DocumentLive.Index, :index
      live "/analytics", AnalyticsLive, :index

      live "/settings/profile", SettingsLive.Profile, :edit
      live "/settings/account", UserLive.Settings, :edit
      live "/settings/account/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/settings/members", SettingsLive.Members, :index
      live "/settings/audit", SettingsLive.Audit, :index
      live "/settings/workspace", SettingsLive.Workspace, :edit
    end

    get "/settings", PageController, :settings
    post "/users/update-password", UserSessionController, :update_password
  end

  ## Public screens: sign in, first-run setup, invitations

  scope "/", ReadoutWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [
        {ReadoutWeb.UserAuth, :mount_current_scope},
        ReadoutWeb.Locale,
        ReadoutWeb.Shell
      ] do
      live "/setup", SetupLive, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
      live "/invitations/:token", InvitationLive, :accept
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  ## Internal tools under /dev (tailnet-only in production, via Caddy)

  if Application.compile_env(:readout, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ReadoutWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    scope "/dev", ReadoutWeb do
      pipe_through [:browser, :require_authenticated_user]

      live_session :dev,
        on_mount: [
          {ReadoutWeb.UserAuth, :require_authenticated},
          ReadoutWeb.Locale,
          ReadoutWeb.Shell
        ] do
        live "/design", Dev.DesignLive, :index
      end
    end
  end
end
