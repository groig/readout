defmodule ReadoutWeb.DocumentComponents do
  @moduledoc "Pieces shared by the documents pages: thumbnails, status, file URLs."
  use ReadoutWeb, :html

  alias Readout.Documents.{Document, Pdf, Version}
  alias ReadoutWeb.DocumentLabels

  @doc "URL of a page image for signed-in team members."
  def page_url(%Document{id: id}, %Version{id: vid}, number, width \\ Pdf.view_width()),
    do: ~p"/documents/#{id}/v/#{vid}/pages/#{number}/#{width}"

  def download_url(%Document{id: id}, %Version{id: vid}, kind),
    do: ~p"/documents/#{id}/v/#{vid}/download/#{kind}"

  @doc """
  The first page of the current version, or a skeleton while the first
  version processes, or a quiet error tile.
  """
  attr :document, Document, required: true
  attr :class, :any, default: nil

  attr :sizes, :string,
    default: "8rem",
    doc: "the rendered width, so the browser picks a sharp image"

  def thumbnail(assigns) do
    assigns =
      assign(assigns,
        current: assigns.document.current_version,
        latest: assigns.document.latest_version
      )

    ~H"""
    <div class={["relative overflow-hidden bg-inset", @class]}>
      <%= cond do %>
        <% @current && @current.status == :ready && Version.kind(@current) == :sheets -> %>
          <div class="flex h-full w-full flex-col gap-1 p-[10%]" aria-hidden="true">
            <div class="flex gap-1">
              <span :for={_ <- 1..4} class="h-2.5 flex-1 rounded-xs bg-accent/30" />
            </div>
            <div :for={_ <- 1..6} class="flex gap-1">
              <span :for={_ <- 1..4} class="h-2 flex-1 rounded-xs bg-active" />
            </div>
            <span class="mt-auto inline-flex items-center gap-1 self-start rounded-sm bg-surface px-1.5 py-0.5 text-2xs font-medium text-fg-muted shadow-xs">
              <.icon name="hero-table-cells-micro" class="size-3" />
              {ngettext("%{count} sheet", "%{count} sheets", @current.page_count)}
            </span>
          </div>
        <% @current && @current.status == :ready -> %>
          <img
            src={page_url(@document, @current, 1, Pdf.thumb_width())}
            srcset={"#{page_url(@document, @current, 1, Pdf.thumb_width())} #{Pdf.thumb_width()}w, #{page_url(@document, @current, 1, Pdf.view_width())} #{Pdf.view_width()}w"}
            sizes={@sizes}
            alt=""
            loading="lazy"
            decoding="async"
            class="h-full w-full object-cover object-top"
          />
        <% @latest && @latest.status == :failed -> %>
          <div class="flex h-full w-full items-center justify-center text-danger">
            <.icon name="hero-exclamation-triangle" class="size-6" />
          </div>
        <% true -> %>
          <div class="flex h-full w-full flex-col gap-2 p-[12%]">
            <.skeleton class="h-2.5 w-2/3" />
            <.skeleton class="h-2 w-full" />
            <.skeleton class="h-2 w-5/6" />
            <.skeleton class="h-2 w-4/6" />
          </div>
      <% end %>
    </div>
    """
  end

  @doc "Status of the latest version, if it isn't simply ready."
  attr :version, :any, required: true

  def status_badge(assigns) do
    ~H"""
    <%= case @version && @version.status do %>
      <% status when status in [:pending, :processing] -> %>
        <.badge tone="accent" pulse>{DocumentLabels.status_label(status)}</.badge>
      <% :failed -> %>
        <.badge tone="danger" dot title={DocumentLabels.error_message(@version.error)}>
          {DocumentLabels.status_label(:failed)}
        </.badge>
      <% _ -> %>
    <% end %>
    """
  end
end
