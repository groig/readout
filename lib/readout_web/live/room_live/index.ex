defmodule ReadoutWeb.RoomLive.Index do
  @moduledoc "Data rooms: several documents shared behind one link."
  use ReadoutWeb, :live_view

  alias Readout.{Policy, Rooms}
  alias Readout.Accounts.User
  alias Readout.Rooms.Room

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:rooms} width="wide">
      <:crumb>{gettext("Rooms")}</:crumb>
      <:actions>
        <.button
          :if={@can_create}
          id="new-room-button"
          variant="primary"
          size="sm"
          icon="hero-plus-mini"
          phx-click="new"
        >
          {gettext("New room")}
        </.button>
      </:actions>

      <.header class="mb-6">
        {gettext("Rooms")}
        <:subtitle>
          {gettext(
            "Share several documents behind one link: a deal, a board pack, an investor update."
          )}
        </:subtitle>
      </.header>

      <div :if={@count == 0} class="rounded-xl border border-dashed border-border-strong">
        <.empty_state id="rooms-empty" icon="hero-rectangle-stack" title={gettext("No rooms yet")}>
          {gettext("Create a room, add documents, then share one link for all of them.")}
          <:actions :if={@can_create}>
            <.button variant="primary" icon="hero-plus-mini" phx-click="new">{gettext("New room")}</.button>
          </:actions>
        </.empty_state>
      </div>

      <div id="rooms" phx-update="stream" class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
        <.link
          :for={{id, room} <- @streams.rooms}
          id={id}
          navigate={~p"/rooms/#{room}"}
          class="ui-enter group flex flex-col rounded-xl border border-border bg-surface p-4 shadow-xs transition-[box-shadow,border-color,transform] duration-(--duration-base) hover:-translate-y-0.5 hover:border-border-strong hover:shadow-md"
        >
          <div class="mb-3 flex items-center gap-3">
            <span class="flex size-9 items-center justify-center rounded-lg bg-accent-soft text-accent-fg">
              <.icon name="hero-rectangle-stack" class="size-5" />
            </span>
            <div class="min-w-0">
              <p class="flex items-center gap-1.5 truncate font-medium text-fg">
                {room.name}
                <.icon
                  :if={room.visibility == :restricted}
                  name="hero-lock-closed-micro"
                  class="size-3 text-fg-subtle"
                />
              </p>
              <p class="truncate text-xs text-fg-subtle">{User.display_name(room.owner)}</p>
            </div>
          </div>
          <p :if={room.description != ""} class="mb-3 line-clamp-2 text-sm text-fg-muted">
            {room.description}
          </p>
          <p class="mt-auto flex gap-2 text-xs text-fg-subtle tabular-nums">
            <span>{ngettext("%{count} document", "%{count} documents", length(room.documents))}</span>
            <span aria-hidden="true">·</span>
            <span>{ngettext("%{count} link", "%{count} links", room.link_count)}</span>
          </p>
        </.link>
      </div>

      <.dialog
        :if={@form}
        id="new-room-dialog"
        show
        title={gettext("New room")}
        on_close={JS.push("close")}
      >
        <.form for={@form} id="room-form" phx-submit="create" phx-change="validate" class="space-y-4">
          <.input
            field={@form[:name]}
            label={gettext("Name")}
            placeholder={gettext("e.g. Series A due diligence")}
            autofocus
          />
          <.input
            field={@form[:description]}
            type="textarea"
            label={gettext("Description")}
            hint={gettext("Optional. Viewers see it above the list of documents.")}
          />
        </.form>
        <:footer>
          <.button phx-click={close_dialog("new-room-dialog")}>{gettext("Cancel")}</.button>
          <.button type="submit" form="room-form" variant="primary" id="create-room">{gettext(
            "Create room"
          )}</.button>
        </:footer>
      </.dialog>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Rooms.subscribe(scope)

    {:ok,
     socket
     |> assign(:page_title, gettext("Rooms"))
     |> assign(:can_create, Policy.can?(scope, :create_room, :workspace))
     |> assign(:form, nil)
     |> load()}
  end

  defp load(socket) do
    rooms = Rooms.list_rooms(socket.assigns.current_scope)
    socket |> assign(:count, length(rooms)) |> stream(:rooms, rooms, reset: true)
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, assign(socket, :form, to_form(Rooms.change_room(%Room{})))}
  end

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, :form, nil)}

  def handle_event("validate", %{"room" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :form,
       to_form(%Room{} |> Rooms.change_room(params) |> Map.put(:action, :validate))
     )}
  end

  def handle_event("create", %{"room" => params}, socket) do
    case Rooms.create_room(socket.assigns.current_scope, params) do
      {:ok, room} -> {:noreply, push_navigate(socket, to: ~p"/rooms/#{room}")}
      {:error, %Ecto.Changeset{} = cs} -> {:noreply, assign(socket, :form, to_form(cs))}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("You can't do that."))}
    end
  end

  @impl true
  def handle_info({:room_updated, _id}, socket), do: {:noreply, load(socket)}
end
