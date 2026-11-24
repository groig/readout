defmodule ReadoutWeb.Router do
  use ReadoutWeb, :router

  import ReadoutWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ReadoutWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "referrer-policy" => "strict-origin-when-cross-origin",
      "permissions-policy" => "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
    }

    plug ReadoutWeb.Plugs.ContentSecurityPolicy
    plug :fetch_current_scope_for_user
    plug ReadoutWeb.Locale
  end

  # The public viewer: no team session needed, the browser's language, and
  # never indexed.
  pipeline :viewer do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ReadoutWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "referrer-policy" => "no-referrer",
      "x-robots-tag" => "noindex, nofollow",
      "permissions-policy" => "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
    }

    plug ReadoutWeb.Plugs.ContentSecurityPolicy
    plug ReadoutWeb.Locale, from: :browser
    plug ReadoutWeb.ViewerAccess
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
      live "/documents/:id", DocumentLive.Show, :show
      live "/documents/:id/versions", DocumentLive.Show, :versions
      live "/documents/:id/links", DocumentLive.Show, :links
      live "/documents/:id/analytics", DocumentLive.Analytics, :index
      live "/analytics", AnalyticsLive, :index
      live "/rooms", RoomLive.Index, :index
      live "/rooms/:id", RoomLive.Show, :show
      live "/rooms/:id/links", RoomLive.Show, :links
      live "/rooms/:id/analytics", RoomLive.Show, :analytics

      live "/settings/profile", SettingsLive.Profile, :edit
      live "/settings/account", UserLive.Settings, :edit
      live "/settings/account/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/settings/members", SettingsLive.Members, :index
      live "/settings/audit", SettingsLive.Audit, :index
      live "/settings/workspace", SettingsLive.Workspace, :edit
    end

    get "/settings", PageController, :settings

    get "/documents/:id/v/:version_id/pages/:number/:width", DocumentFileController, :page
    get "/documents/:id/v/:version_id/download/:kind", DocumentFileController, :download
    get "/documents/:id/analytics/export/:kind", AnalyticsExportController, :show
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
      live "/users/reset-password", UserLive.ResetPassword, :new
      live "/users/reset-password/:token", UserLive.ResetPassword, :edit
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  ## Public viewer: /v/:slug (the only thing a share link exposes)

  scope "/v", ReadoutWeb do
    pipe_through :viewer

    live_session :viewer, on_mount: [{ReadoutWeb.Locale, :browser}] do
      live "/:slug", ViewerLive, :show
      live "/:slug/d/:document_id", ViewerLive, :room_document
    end

    post "/:slug/access", ViewerAccessController, :create
    get "/:slug/p/:token/:number/:width", ViewerFileController, :page
    get "/:slug/download/:token/:kind", ViewerFileController, :download
  end

  ## Internal tools under /dev: tailnet-only in production (one Caddy rule
  ## covers the prefix). LiveDashboard also requires an owner or admin.

  import Phoenix.LiveDashboard.Router

  scope "/dev" do
    pipe_through [:browser, :require_authenticated_user, :require_workspace_admin]

    live_dashboard "/dashboard",
      metrics: ReadoutWeb.Telemetry,
      on_mount: [{ReadoutWeb.UserAuth, {:can, :manage_members}}]
  end

  if Application.compile_env(:readout, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

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
