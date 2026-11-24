defmodule ReadoutWeb.AnalyticsLive do
  @moduledoc "Workspace-wide analytics and the live activity feed."
  use ReadoutWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:analytics}>
      <:crumb>{gettext("Analytics")}</:crumb>

      <.header class="mb-8">
        {gettext("Analytics")}
        <:subtitle>{gettext("Who is reading what, live.")}</:subtitle>
      </.header>

      <div class="rounded-xl border border-dashed border-border-strong">
        <.empty_state
          id="analytics-empty"
          icon="hero-chart-bar"
          title={gettext("No reading activity yet")}
        >
          {gettext(
            "Share a document with a link. Visits and time per page appear here as people read."
          )}
        </.empty_state>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Analytics"))}
  end
end
