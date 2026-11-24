defmodule ReadoutWeb.DocumentLive.Index do
  @moduledoc "The documents list."
  use ReadoutWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:documents}>
      <:crumb>{gettext("Documents")}</:crumb>

      <.header class="mb-8">
        {gettext("Documents")}
        <:subtitle>{gettext("Reports, proposals and decks you share with links.")}</:subtitle>
      </.header>

      <div class="rounded-xl border border-dashed border-border-strong">
        <.empty_state
          id="documents-empty"
          icon="hero-document-arrow-up"
          title={gettext("No documents yet")}
        >
          {gettext("Upload a PDF, Word or PowerPoint file to start sharing it.")}
        </.empty_state>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Documents"))}
  end
end
