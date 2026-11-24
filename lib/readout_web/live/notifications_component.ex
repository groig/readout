defmodule ReadoutWeb.NotificationsComponent do
  @moduledoc """
  The bell in the sidebar: unread count, the notifications sheet, and a toast
  when something new arrives. A LiveComponent because the shell renders it on
  every page; `ReadoutWeb.Shell` forwards new notifications with
  `send_update/2`.
  """
  use ReadoutWeb, :live_component

  alias Readout.Notifications
  alias ReadoutWeb.NotificationLabels

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(loaded?: false)
     |> stream_configure(:items, dom_id: &"notification-#{&1.id}")}
  end

  @impl true
  def update(%{new: id}, socket) do
    scope = socket.assigns.current_scope

    case Notifications.get(scope, id) do
      nil ->
        {:ok, socket}

      notification ->
        {:ok,
         socket
         |> assign(:unread, Notifications.unread_count(scope))
         |> stream_insert(:items, notification, at: 0)
         |> push_event("toast", %{
           message: NotificationLabels.text(notification, socket.assigns.locale)
         })}
    end
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if socket.assigns.loaded? do
      {:ok, socket}
    else
      scope = socket.assigns.current_scope

      {:ok,
       socket
       |> assign(loaded?: true, unread: Notifications.unread_count(scope))
       |> stream(:items, Notifications.list(scope))}
    end
  end

  @impl true
  def handle_event("open", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Notifications.get(scope, id) do
      nil ->
        {:noreply, socket}

      n ->
        Notifications.mark_read(scope, n.id)

        to =
          if n.visit_id,
            do: ~p"/documents/#{n.document_id}/analytics?#{%{visit: n.visit_id}}",
            else: ~p"/documents/#{n.document_id}"

        {:noreply, push_navigate(socket, to: to)}
    end
  end

  def handle_event("read_all", _params, socket) do
    scope = socket.assigns.current_scope
    Notifications.mark_all_read(scope)

    {:noreply,
     socket |> assign(:unread, 0) |> stream(:items, Notifications.list(scope), reset: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="contents">
      <span class="ui-has-tooltip relative inline-flex">
        <button
          id="notifications-button"
          type="button"
          data-shortcut="n"
          aria-label={gettext("Notifications")}
          phx-click={open_dialog("notifications-sheet")}
          class="relative flex size-7 cursor-pointer items-center justify-center rounded-md text-fg-subtle transition-colors hover:bg-hover hover:text-fg active:scale-95"
        >
          <.icon name="hero-bell" class="size-4.5" />
          <span
            :if={@unread > 0}
            id="notifications-unread"
            class="absolute -top-0.5 -right-0.5 flex h-4 min-w-4 items-center justify-center rounded-full bg-accent px-1 text-[0.625rem] font-semibold text-on-accent tabular-nums ring-2 ring-sidebar"
          >
            {if @unread > 99, do: "99+", else: @unread}
          </span>
        </button>
        <span role="tooltip" class={tooltip_classes("top")}>{gettext("Notifications")}</span>
      </span>

      <.sheet id="notifications-sheet" title={gettext("Notifications")} width="26rem">
        <div :if={@unread > 0} class="mb-3 flex justify-end">
          <.button id="read-all" size="sm" variant="ghost" phx-click="read_all" phx-target={@myself}>
            {gettext("Mark all as read")}
          </.button>
        </div>
        <ol id="notification-list" phx-update="stream" class="-mx-2 space-y-0.5">
          <li id="notifications-empty" class="hidden only:block">
            <.empty_state icon="hero-bell" title={gettext("No notifications yet")}>
              {gettext("Follow a document with the bell on its page to hear when it's read.")}
            </.empty_state>
          </li>
          <li :for={{dom_id, n} <- @streams.items} id={dom_id} class="ui-enter">
            <button
              type="button"
              phx-click={
                close_dialog("notifications-sheet")
                |> JS.push("open", value: %{id: n.id}, target: @myself)
              }
              class="flex w-full cursor-pointer items-start gap-3 rounded-lg px-2 py-2.5 text-left transition-colors hover:bg-hover"
            >
              <span class={[
                "mt-0.5 flex size-7 shrink-0 items-center justify-center rounded-full",
                n.kind == "version_failed" && "bg-danger-soft text-danger-fg",
                n.kind != "version_failed" && "bg-accent-soft text-accent-fg"
              ]}>
                <.icon name={NotificationLabels.icon(n)} class="size-4" />
              </span>
              <span class="min-w-0 flex-1">
                <span class={[
                  "block text-sm",
                  if(n.read_at, do: "text-fg-muted", else: "font-medium text-fg")
                ]}>
                  {NotificationLabels.text(n, @locale)}
                </span>
                <span :if={NotificationLabels.detail(n, @locale)} class="block text-xs text-fg-subtle">
                  {NotificationLabels.detail(n, @locale)}
                </span>
                <.relative_time
                  at={n.inserted_at}
                  scope={@current_scope}
                  class="text-xs text-fg-subtle"
                />
              </span>
              <span
                :if={!n.read_at}
                class="mt-2 size-2 shrink-0 rounded-full bg-accent"
                aria-label={gettext("Unread")}
              />
            </button>
          </li>
        </ol>
      </.sheet>
    </div>
    """
  end
end
