defmodule ReadoutWeb.RoomLive.Show do
  @moduledoc """
  A data room: its documents (add, order, remove), links (same settings as
  document links) and analytics (totals, per document, recent visits).
  """
  use ReadoutWeb, :live_view

  import ReadoutWeb.DocumentLive.LinkComponents

  alias Readout.{Analytics, GeoIP, Links, Policy, Rooms}
  alias Readout.Documents.Version
  alias Readout.Links.Link

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:rooms} width="wide">
      <:crumb navigate={~p"/rooms"}>{gettext("Rooms")}</:crumb>
      <:crumb>{@room.name}</:crumb>
      <:actions>
        <.button
          :if={@can_edit}
          id="share-room"
          size="sm"
          variant="primary"
          icon="hero-link-mini"
          phx-click="new_link"
        >
          {gettext("Share")}
        </.button>
        <.dropdown :if={@can_edit} id="room-actions">
          <:trigger>
            <.icon_button icon="hero-ellipsis-horizontal-mini" label={gettext("More actions")} />
          </:trigger>
          <:item icon="hero-pencil-square-mini" phx-click="edit">{gettext("Edit details")}</:item>
          <:item :if={@can_manage} separator />
          <:item
            :if={@can_manage}
            icon="hero-trash-mini"
            danger
            phx-click={open_dialog("delete-room-dialog")}
          >
            {gettext("Delete")}
          </:item>
        </.dropdown>
      </:actions>

      <header class="mb-6">
        <h1 id="room-name" class="flex items-center gap-2 text-2xl font-semibold text-fg">
          {@room.name}
          <.badge :if={@room.visibility == :restricted}>
            <.icon name="hero-lock-closed-micro" class="size-3" />{gettext("Restricted")}
          </.badge>
        </h1>
        <p
          :if={@room.description != ""}
          class="mt-1 max-w-3xl whitespace-pre-line text-md text-fg-muted"
        >
          {@room.description}
        </p>
      </header>

      <.tabs id="room-tabs" class="mb-6">
        <:tab
          patch={~p"/rooms/#{@room}"}
          active={@live_action == :show}
          count={length(@room.documents)}
          id="tab-room-docs"
        >
          {gettext("Documents")}
        </:tab>
        <:tab
          patch={~p"/rooms/#{@room}/links"}
          active={@live_action == :links}
          count={@link_count}
          id="tab-room-links"
        >
          {gettext("Links")}
        </:tab>
        <:tab
          patch={~p"/rooms/#{@room}/analytics"}
          active={@live_action == :analytics}
          id="tab-room-analytics"
        >
          {gettext("Analytics")}
        </:tab>
      </.tabs>

      <%= case @live_action do %>
        <% :show -> %>
          <div :if={@can_edit} class="mb-4 flex justify-end">
            <.button id="add-documents" icon="hero-plus-mini" phx-click="open_add">{gettext(
              "Add documents"
            )}</.button>
          </div>
          <div
            :if={@room.documents == []}
            class="rounded-xl border border-dashed border-border-strong"
          >
            <.empty_state
              id="room-docs-empty"
              icon="hero-document-plus"
              title={gettext("No documents in this room")}
            >
              {gettext(
                "Add the documents you want to share together. Viewers see them in this order."
              )}
            </.empty_state>
          </div>
          <ol :if={@room.documents != []} id="room-documents" class="space-y-2">
            <li
              :for={{doc, i} <- Enum.with_index(@room.documents, 1)}
              id={"room-document-#{doc.id}"}
              class="flex items-center gap-3 rounded-lg border border-border bg-surface px-3 py-2.5 shadow-xs"
            >
              <span class="w-5 text-right text-sm text-fg-subtle tabular-nums">{i}</span>
              <.link navigate={~p"/documents/#{doc}"} class="min-w-0 flex-1">
                <span class="block truncate font-medium text-fg hover:underline">{doc.title}</span>
                <span class="block text-xs text-fg-subtle">
                  <%= if doc.current_version do %>
                    {ngettext("%{count} page", "%{count} pages", doc.current_version.page_count)}
                  <% else %>
                    {gettext("Not ready yet: hidden from viewers until processed.")}
                  <% end %>
                </span>
              </.link>
              <div :if={@can_edit} class="flex items-center gap-0.5">
                <.icon_button
                  icon="hero-arrow-up-mini"
                  label={gettext("Move up")}
                  size="xs"
                  phx-click="move"
                  phx-value-id={doc.id}
                  phx-value-dir="up"
                  disabled={i == 1}
                />
                <.icon_button
                  icon="hero-arrow-down-mini"
                  label={gettext("Move down")}
                  size="xs"
                  phx-click="move"
                  phx-value-id={doc.id}
                  phx-value-dir="down"
                  disabled={i == length(@room.documents)}
                />
                <.icon_button
                  icon="hero-x-mark-mini"
                  label={gettext("Remove from room")}
                  size="xs"
                  phx-click="remove"
                  phx-value-id={doc.id}
                />
              </div>
            </li>
          </ol>
        <% :links -> %>
          <.links_table
            links={@streams.links}
            count={@link_count}
            can_edit={@can_edit}
            scope={@current_scope}
          />
        <% :analytics -> %>
          <div class="mb-6 grid gap-3 sm:grid-cols-3">
            <.stat_tile
              id="room-visits"
              label={gettext("Visits")}
              value={Format.number(@overview.totals.visits)}
              icon="hero-eye"
            />
            <.stat_tile
              id="room-unique"
              label={gettext("Unique viewers")}
              value={Format.number(@overview.totals.unique)}
              icon="hero-users"
            />
            <.stat_tile
              id="room-time"
              label={gettext("Average time per document")}
              value={Format.duration(div(@overview.totals.avg_ms, 1000))}
              icon="hero-clock"
            />
          </div>
          <div class="grid gap-6 xl:grid-cols-2">
            <.card id="room-per-document" title={gettext("By document")}>
              <.bar_list
                id="room-per-document-list"
                items={
                  for d <- @overview.per_document,
                      do: %{
                        label: d.title,
                        value: d.visits,
                        display:
                          "#{ngettext("%{count} visit", "%{count} visits", d.visits)} · #{Format.duration(div(d.avg_ms, 1000))}"
                      }
                }
              />
              <p :if={@overview.per_document == []} class="text-sm text-fg-subtle">
                {gettext("No documents in this room.")}
              </p>
            </.card>
            <section>
              <h2 class="mb-3 text-md font-semibold text-fg">{gettext("Recent visits")}</h2>
              <.table
                id="room-visits-table"
                rows={@overview.recent}
                row_id={&"room-visit-#{&1.id}"}
                row_click={
                  &JS.navigate(~p"/documents/#{&1.document_id}/analytics?#{%{visit: &1.id}}")
                }
              >
                <:col :let={v} label={gettext("Viewer")}>{viewer_name(v, @locale)}</:col>
                <:col :let={v} label={gettext("Document")} class="text-fg-muted">
                  {v.document.title}
                </:col>
                <:col :let={v} label={gettext("Time")} numeric>
                  {Format.duration(div(v.duration_ms, 1000))}
                </:col>
                <:col :let={v} label={gettext("When")} class="text-fg-muted">
                  <.relative_time at={v.started_at} scope={@current_scope} />
                </:col>
                <:empty><.empty_state icon="hero-eye" title={gettext("No visits yet")} /></:empty>
              </.table>
            </section>
          </div>
      <% end %>

      <.dialog
        :if={@adding}
        id="add-documents-dialog"
        show
        title={gettext("Add documents")}
        on_close={JS.push("close_add")}
        width="36rem"
      >
        <.form for={%{}} id="add-search" phx-change="search_add" class="mb-3">
          <.search_input
            id="add-query"
            name="q"
            value={@add_query}
            placeholder={gettext("Search your documents")}
            phx-debounce="150"
          />
        </.form>
        <p :if={@candidates == []} class="py-6 text-center text-sm text-fg-subtle">
          {gettext("No more documents you can share.")}
        </p>
        <ul
          :if={@candidates != []}
          class="max-h-80 divide-y divide-border overflow-y-auto rounded-lg border border-border"
        >
          <li
            :for={doc <- @candidates}
            id={"candidate-#{doc.id}"}
            class="flex items-center gap-3 px-3 py-2"
          >
            <span class="min-w-0 flex-1 truncate text-sm text-fg">{doc.title}</span>
            <.button size="xs" phx-click="add" phx-value-id={doc.id}>{gettext("Add")}</.button>
          </li>
        </ul>
        <:footer>
          <.button phx-click={close_dialog("add-documents-dialog")}>{gettext("Done")}</.button>
        </:footer>
      </.dialog>

      <.dialog
        :if={@details_form}
        id="room-details-dialog"
        show
        title={gettext("Edit details")}
        on_close={JS.push("close_details")}
      >
        <.form for={@details_form} id="room-details-form" phx-submit="save_details" class="space-y-4">
          <.input field={@details_form[:name]} label={gettext("Name")} />
          <.input field={@details_form[:description]} type="textarea" label={gettext("Description")} />
          <.input
            :if={@can_manage}
            field={@details_form[:visibility]}
            type="segmented"
            label={gettext("Who in the team can see it")}
            options={[
              {gettext("Workspace"), "workspace"},
              {gettext("Only me and admins"), "restricted"}
            ]}
          />
        </.form>
        <:footer>
          <.button phx-click={close_dialog("room-details-dialog")}>{gettext("Cancel")}</.button>
          <.button type="submit" form="room-details-form" variant="primary" id="save-room-details">{gettext(
            "Save"
          )}</.button>
        </:footer>
      </.dialog>

      <.dialog
        :if={@can_manage}
        id="delete-room-dialog"
        title={gettext("Delete “%{name}”?", name: @room.name)}
      >
        <p class="text-sm text-fg-muted">
          {gettext("Its links stop working right away. The documents themselves are not deleted.")}
        </p>
        <:footer>
          <.button phx-click={close_dialog("delete-room-dialog")}>{gettext("Cancel")}</.button>
          <.button id="confirm-delete-room" variant="danger" phx-click="delete">{gettext("Delete")}</.button>
        </:footer>
      </.dialog>

      <.link_sheet
        :if={@editing_link}
        form={@link_form}
        link={@editing_link}
        expires_on={@expires_on}
        mail_enabled={@mail_enabled}
        office?={office?(@room)}
      />
    </Layouts.app>
    """
  end

  ## Mount and params

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Rooms.get_room(socket.assigns.current_scope, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That room doesn't exist or you can't see it."))
         |> push_navigate(to: ~p"/rooms")}

      room ->
        if connected?(socket), do: Rooms.subscribe(socket.assigns.current_scope)

        {:ok,
         socket
         |> assign(adding: false, add_query: "", candidates: [], details_form: nil)
         |> assign(editing_link: nil, link_form: nil, expires_on: "", link_count: 0)
         |> assign(:mail_enabled, Readout.Mailer.enabled?())
         |> stream_configure(:links, dom_id: &"links-#{&1.id}")
         |> assign_room(room)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = socket |> load_links() |> load_analytics()

    socket =
      if params["new"] && socket.assigns.can_edit, do: open_link(socket, %Link{}), else: socket

    {:noreply, socket}
  end

  defp assign_room(socket, room) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:room, room)
    |> assign(:page_title, room.name)
    |> assign(:can_edit, Policy.can?(scope, :edit_room, room))
    |> assign(:can_manage, Policy.can?(scope, :manage_room, room))
  end

  defp reload(socket) do
    case Rooms.get_room(socket.assigns.current_scope, socket.assigns.room.id) do
      nil ->
        socket
        |> put_flash(:info, gettext("This room is no longer available."))
        |> push_navigate(to: ~p"/rooms")

      room ->
        socket |> assign_room(room) |> load_links() |> load_analytics() |> refresh_candidates()
    end
  end

  defp load_links(socket) do
    links = Links.list_links(socket.assigns.current_scope, socket.assigns.room)
    socket |> assign(:link_count, length(links)) |> stream(:links, links, reset: true)
  end

  defp load_analytics(%{assigns: %{live_action: :analytics}} = socket) do
    assign(
      socket,
      :overview,
      Analytics.room_overview(socket.assigns.current_scope, socket.assigns.room)
    )
  end

  defp load_analytics(socket), do: socket

  defp office?(room),
    do: Enum.any?(room.documents, &(&1.current_version && Version.office?(&1.current_version)))

  ## Documents

  @impl true
  def handle_event("open_add", _params, socket) do
    {:noreply, socket |> assign(adding: true, add_query: "") |> refresh_candidates()}
  end

  def handle_event("close_add", _params, socket), do: {:noreply, assign(socket, :adding, false)}

  def handle_event("search_add", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:add_query, q) |> refresh_candidates()}
  end

  def handle_event("add", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with %{} = doc <- Readout.Documents.get_document(scope, id),
         {:ok, _} <- Rooms.add_document(scope, socket.assigns.room, doc) do
      {:noreply, reload(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("You can't do that."))}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    case Rooms.remove_document(socket.assigns.current_scope, socket.assigns.room, id) do
      :ok -> {:noreply, reload(socket)}
      _ -> {:noreply, put_flash(socket, :error, gettext("You can't do that."))}
    end
  end

  def handle_event("move", %{"id" => id, "dir" => dir}, socket) when dir in ["up", "down"] do
    case Rooms.move_document(
           socket.assigns.current_scope,
           socket.assigns.room,
           id,
           String.to_existing_atom(dir)
         ) do
      :ok -> {:noreply, reload(socket)}
      _ -> {:noreply, put_flash(socket, :error, gettext("You can't do that."))}
    end
  end

  ## Details and deletion

  def handle_event("edit", _params, socket) do
    {:noreply, assign(socket, :details_form, to_form(Rooms.change_room(socket.assigns.room)))}
  end

  def handle_event("close_details", _params, socket),
    do: {:noreply, assign(socket, :details_form, nil)}

  def handle_event("save_details", %{"room" => params}, socket) do
    case Rooms.update_room(socket.assigns.current_scope, socket.assigns.room, params) do
      {:ok, _} -> {:noreply, socket |> assign(:details_form, nil) |> reload()}
      {:error, %Ecto.Changeset{} = cs} -> {:noreply, assign(socket, :details_form, to_form(cs))}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("You can't do that."))}
    end
  end

  def handle_event("delete", _params, socket) do
    case Rooms.delete_room(socket.assigns.current_scope, socket.assigns.room) do
      {:ok, room} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("“%{name}” was deleted.", name: room.name))
         |> push_navigate(to: ~p"/rooms")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("You can't do that."))}
    end
  end

  ## Links (same settings sheet as document links)

  def handle_event("new_link", _params, socket) do
    {:noreply, if(socket.assigns.can_edit, do: open_link(socket, %Link{}), else: socket)}
  end

  def handle_event("edit_link", %{"id" => id}, socket) do
    case Links.get_link(socket.assigns.room, id) do
      nil -> {:noreply, socket}
      link -> {:noreply, open_link(socket, link)}
    end
  end

  def handle_event("close_link", _params, socket),
    do: {:noreply, assign(socket, editing_link: nil, link_form: nil)}

  def handle_event("validate_link", %{"link" => params}, socket) do
    params = link_params(params, socket.assigns.current_scope.timezone)

    form =
      socket.assigns.editing_link
      |> Links.change_link(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply,
     assign(socket,
       link_form: form,
       expires_on: params["expires_on"] || socket.assigns.expires_on
     )}
  end

  def handle_event("save_link", %{"link" => params}, socket) do
    %{current_scope: scope, room: room, editing_link: link} = socket.assigns
    params = link_params(params, scope.timezone)

    result =
      if link.id,
        do: Links.update_link(scope, room, link, params),
        else: Links.create_link(scope, room, params)

    case result do
      {:ok, saved} ->
        message =
          if link.id,
            do: gettext("Link saved."),
            else: gettext("Link “%{name}” created. Copy it from the list.", name: saved.name)

        {:noreply,
         socket
         |> assign(editing_link: nil, link_form: nil)
         |> put_flash(:info, message)
         |> load_links()
         |> then(
           &if(&1.assigns.live_action == :links,
             do: &1,
             else: push_patch(&1, to: ~p"/rooms/#{room}/links")
           )
         )}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :link_form, to_form(cs))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("You can't do that."))}
    end
  end

  @impl true
  def handle_info({:room_updated, id}, socket) do
    if id == socket.assigns.room.id, do: {:noreply, reload(socket)}, else: {:noreply, socket}
  end

  defp open_link(socket, %Link{} = link) do
    socket
    |> assign(
      editing_link: link,
      expires_on: expires_on(link, socket.assigns.current_scope.timezone)
    )
    |> assign(:link_form, to_form(Links.change_link(link)))
  end

  defp refresh_candidates(%{assigns: %{adding: false}} = socket), do: socket

  defp refresh_candidates(socket) do
    q = socket.assigns.add_query |> String.trim() |> String.downcase()

    candidates =
      socket.assigns.current_scope
      |> Rooms.addable_documents(socket.assigns.room)
      |> Enum.filter(&(q == "" or String.contains?(String.downcase(&1.title), q)))

    assign(socket, :candidates, candidates)
  end

  defp viewer_name(%{email: email}, _locale) when is_binary(email), do: email

  defp viewer_name(v, locale) do
    case GeoIP.label(%{country: v.country || %{}, city: v.city || %{}}, locale) do
      nil -> gettext("Anonymous")
      place -> gettext("Anonymous · %{place}", place: place)
    end
  end
end
