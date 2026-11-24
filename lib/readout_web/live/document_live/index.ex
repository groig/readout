defmodule ReadoutWeb.DocumentLive.Index do
  @moduledoc """
  The documents list: grid or list view, search (title and page text), sort,
  inline rename. Uploads and processing status show up live.
  """
  use ReadoutWeb, :live_view

  import ReadoutWeb.DocumentComponents

  alias Readout.{Documents, Policy}
  alias Readout.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:documents} width="wide">
      <:crumb>{gettext("Documents")}</:crumb>
      <:actions>
        <.button
          :if={@can_upload}
          id="upload-button"
          variant="primary"
          size="sm"
          icon="hero-arrow-up-tray-mini"
          phx-click={JS.dispatch("readout:pick-file")}
        >
          {gettext("Upload")}
        </.button>
      </:actions>

      <.header class="mb-6">
        {gettext("Documents")}
        <:subtitle>{gettext("Reports, proposals and decks you share with links.")}</:subtitle>
      </.header>

      <div class="mb-5 flex flex-wrap items-center gap-2">
        <.form
          for={@filter_form}
          id="document-filters"
          phx-change="filter"
          phx-submit="filter"
          class="flex flex-1 flex-wrap items-center gap-2"
        >
          <.search_input
            id="document-search"
            name="q"
            value={@params["q"]}
            placeholder={gettext("Search titles and text")}
            shortcut
            phx-debounce="200"
            class="w-full sm:w-80"
          />
          <.input
            type="select"
            name="sort"
            id="document-sort"
            value={@params["sort"]}
            options={[
              {gettext("Recently updated"), "recent"},
              {gettext("Newest first"), "created"},
              {gettext("Name"), "title"}
            ]}
            wrapper_class="w-44"
          />
          <input type="hidden" name="view" value={@params["view"]} />
        </.form>
        <.segmented id="document-view">
          <:item
            patch={~p"/documents?#{Map.put(@params, "view", "grid")}"}
            active={@params["view"] == "grid"}
            icon="hero-squares-2x2-mini"
            label={gettext("Grid")}
            icon_only
          />
          <:item
            patch={~p"/documents?#{Map.put(@params, "view", "list")}"}
            active={@params["view"] == "list"}
            icon="hero-list-bullet-mini"
            label={gettext("List")}
            icon_only
          />
        </.segmented>
      </div>

      <%= cond do %>
        <% @total == 0 and @params["q"] in [nil, ""] -> %>
          <div class="rounded-xl border border-dashed border-border-strong">
            <.empty_state
              id="documents-empty"
              icon="hero-document-arrow-up"
              title={gettext("No documents yet")}
            >
              {gettext(
                "Upload a PDF, Word or PowerPoint file to start sharing it. You can also drop files anywhere."
              )}
              <:actions :if={@can_upload}>
                <.button
                  variant="primary"
                  icon="hero-arrow-up-tray-mini"
                  phx-click={JS.dispatch("readout:pick-file")}
                >
                  {gettext("Upload a document")}
                </.button>
              </:actions>
            </.empty_state>
          </div>
        <% @params["view"] == "list" -> %>
          <.table id="documents" rows={@streams.documents}>
            <:col :let={{_id, doc}} label={gettext("Name")}>
              <.link navigate={~p"/documents/#{doc}"} class="flex min-w-0 items-center gap-3">
                <.thumbnail
                  document={doc}
                  class="h-10 w-8 shrink-0 rounded-sm border border-border"
                />
                <div class="min-w-0">
                  <p class="flex items-center gap-2 truncate font-medium text-fg">
                    {doc.title}
                    <.icon
                      :if={doc.visibility == :restricted}
                      name="hero-lock-closed-micro"
                      class="size-3 text-fg-subtle"
                    />
                  </p>
                  <.status_badge version={doc.latest_version} />
                </div>
              </.link>
            </:col>
            <:col :let={{_id, doc}} label={gettext("Pages")} numeric>
              {pages(doc)}
            </:col>
            <:col :let={{_id, doc}} label={gettext("Links")} numeric>{doc.link_count}</:col>
            <:col :let={{_id, doc}} label={gettext("Views (7d)")} numeric>{doc.views_7d}</:col>
            <:col :let={{_id, doc}} label={gettext("Owner")}>
              <span class="flex items-center gap-2 text-fg-muted">
                <.avatar name={User.display_name(doc.owner)} color={doc.owner.avatar_color} size="xs" />
                {User.display_name(doc.owner)}
              </span>
            </:col>
            <:col :let={{_id, doc}} label={gettext("Updated")} class="text-fg-muted">
              <.relative_time at={doc.updated_at} scope={@current_scope} />
            </:col>
            <:action :let={{id, doc}}>
              <.document_menu id={"#{id}-menu"} document={doc} scope={@current_scope} />
            </:action>
            <:empty>
              <.empty_state icon="hero-magnifying-glass" title={gettext("No documents match")}>
                {gettext("Try other words. Search looks in titles and in the text of every page.")}
              </.empty_state>
            </:empty>
          </.table>
        <% true -> %>
          <div class="@container">
            <div
              id="documents"
              phx-update="stream"
              class="grid grid-cols-1 gap-4 @md:grid-cols-2 @3xl:grid-cols-3 @6xl:grid-cols-4"
            >
              <div
                id="documents-empty-search"
                class="hidden only:block @md:col-span-2 @3xl:col-span-3 @6xl:col-span-4"
              >
                <.empty_state icon="hero-magnifying-glass" title={gettext("No documents match")}>
                  {gettext("Try other words. Search looks in titles and in the text of every page.")}
                </.empty_state>
              </div>
              <article
                :for={{id, doc} <- @streams.documents}
                id={id}
                class="ui-enter group relative flex flex-col overflow-hidden rounded-xl border border-border bg-surface shadow-xs transition-[box-shadow,border-color,transform] duration-(--duration-base) ease-(--ease-out) hover:-translate-y-0.5 hover:border-border-strong hover:shadow-md"
              >
                <.link navigate={~p"/documents/#{doc}"} class="block" tabindex="-1" aria-hidden="true">
                  <.thumbnail
                    document={doc}
                    sizes="(min-width: 1280px) 25vw, (min-width: 768px) 33vw, 100vw"
                    class="aspect-[4/3] border-b border-border"
                  />
                </.link>
                <div class="flex items-start gap-2 p-3">
                  <div class="min-w-0 flex-1">
                    <%= if @renaming == doc.id do %>
                      <.form
                        for={@rename_form}
                        id={"rename-#{doc.id}"}
                        phx-submit="save_rename"
                        phx-value-id={doc.id}
                      >
                        <input
                          type="text"
                          name="title"
                          value={doc.title}
                          maxlength="200"
                          aria-label={gettext("Title")}
                          phx-mounted={JS.focus() |> JS.dispatch("readout:select")}
                          phx-blur={JS.dispatch("submit", to: "#rename-#{doc.id}")}
                          phx-keydown="cancel_rename"
                          phx-key="Escape"
                          class="-mx-1 -my-0.5 h-7 w-full rounded-md border border-accent bg-surface px-1 text-sm font-medium text-fg ring-3 ring-accent/20 outline-none"
                        />
                      </.form>
                    <% else %>
                      <.link
                        navigate={~p"/documents/#{doc}"}
                        class="block truncate text-sm font-medium text-fg after:absolute after:inset-0 after:content-['']"
                        title={doc.title}
                      >
                        {doc.title}
                      </.link>
                    <% end %>
                    <p class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-fg-subtle tabular-nums">
                      <span :if={doc.visibility == :restricted} class="flex items-center gap-0.5">
                        <.icon name="hero-lock-closed-micro" class="size-3" />
                      </span>
                      <span>{pages(doc)}</span>
                      <span aria-hidden="true">·</span>
                      <span>{ngettext("%{count} link", "%{count} links", doc.link_count)}</span>
                      <span aria-hidden="true">·</span>
                      <span>{ngettext(
                        "%{count} view this week",
                        "%{count} views this week",
                        doc.views_7d
                      )}</span>
                    </p>
                    <div class="mt-1.5 empty:hidden">
                      <.status_badge version={doc.latest_version} />
                    </div>
                  </div>
                  <div class="relative z-10">
                    <.document_menu id={"#{id}-menu"} document={doc} scope={@current_scope} />
                  </div>
                </div>
              </article>
            </div>
          </div>
      <% end %>

      <.dialog
        :if={@confirm_delete}
        id="delete-document-dialog"
        show
        title={gettext("Delete “%{title}”?", title: @confirm_delete.title)}
        on_close={JS.push("cancel_delete")}
      >
        <p class="text-sm text-fg-muted">
          {gettext("Its files and links stop working right away. Reading history is kept.")}
        </p>
        <:footer>
          <.button phx-click={close_dialog("delete-document-dialog")}>{gettext("Cancel")}</.button>
          <.button
            id="confirm-delete-document"
            variant="danger"
            phx-click="delete"
            phx-value-id={@confirm_delete.id}
          >
            {gettext("Delete")}
          </.button>
        </:footer>
      </.dialog>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :document, :any, required: true
  attr :scope, :any, required: true

  defp document_menu(assigns) do
    ~H"""
    <.dropdown id={@id}>
      <:trigger>
        <.icon_button
          icon="hero-ellipsis-horizontal-mini"
          label={gettext("Actions for %{name}", name: @document.title)}
          tooltip={false}
          size="xs"
        />
      </:trigger>
      <:item icon="hero-arrow-top-right-on-square-mini" navigate={~p"/documents/#{@document}"}>
        {gettext("Open")}
      </:item>
      <:item
        :if={Policy.can?(@scope, :edit_document, @document)}
        icon="hero-pencil-square-mini"
        phx-click="rename"
        phx-value-id={@document.id}
      >
        {gettext("Rename")}
      </:item>
      <:item :if={Policy.can?(@scope, :manage_document, @document)} separator />
      <:item
        :if={Policy.can?(@scope, :manage_document, @document)}
        icon="hero-trash-mini"
        danger
        phx-click="confirm_delete"
        phx-value-id={@document.id}
      >
        {gettext("Delete")}
      </:item>
    </.dropdown>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Documents"))
     |> assign(
       :can_upload,
       Policy.can?(socket.assigns.current_scope, :upload_document, :workspace)
     )
     |> assign(renaming: nil, rename_form: to_form(%{}), confirm_delete: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params =
      %{"q" => "", "sort" => "recent", "view" => "grid"}
      |> Map.merge(Map.take(params, ["q", "sort", "view"]))
      |> Map.update!("view", &if(&1 in ["grid", "list"], do: &1, else: "grid"))

    {:noreply,
     socket
     |> assign(:params, params)
     |> assign(:filter_form, to_form(params))
     |> load()}
  end

  defp load(socket) do
    %{"q" => q, "sort" => sort} = socket.assigns.params
    documents = Documents.list_documents(socket.assigns.current_scope, query: q, sort: sort)

    socket
    |> assign_ids(MapSet.new(documents, & &1.id))
    |> stream(:documents, documents, reset: true)
  end

  # The ids on screen: events about anything else (documents this person
  # can't see) must not change the list.
  defp assign_ids(socket, ids), do: assign(socket, ids: ids, total: MapSet.size(ids))

  @doc false
  # Live updates (see ReadoutWeb.Shell). Searches and sorts re-run; otherwise
  # the one document is refreshed in place.
  def handle_document_event(event, id, socket) do
    searching? = socket.assigns.params["q"] != ""

    shown? = MapSet.member?(socket.assigns.ids, id)

    case {event, Documents.get_document(socket.assigns.current_scope, id)} do
      {_, nil} when shown? ->
        socket
        |> stream_delete_by_dom_id(:documents, "documents-#{id}")
        |> assign_ids(MapSet.delete(socket.assigns.ids, id))

      {_, nil} ->
        socket

      {_, _doc} when searching? ->
        load(socket)

      {_, doc} when shown? ->
        stream_insert(socket, :documents, doc)

      {_, doc} ->
        # New to this person: created, or just shared with them.
        socket
        |> assign_ids(MapSet.put(socket.assigns.ids, id))
        |> stream_insert(:documents, doc, at: 0)
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    params =
      socket.assigns.params
      |> Map.merge(Map.take(params, ["q", "sort"]))
      |> Enum.reject(fn {k, v} ->
        v in [nil, ""] or {k, v} in [{"sort", "recent"}, {"view", "grid"}]
      end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/documents?#{params}", replace: true)}
  end

  def handle_event("rename", %{"id" => id}, socket) do
    case Documents.get_document(socket.assigns.current_scope, id) do
      nil ->
        {:noreply, socket}

      doc ->
        socket = maybe_restore(socket)

        {:noreply,
         socket
         |> assign(:renaming, doc.id)
         |> stream_insert(:documents, doc)}
    end
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, maybe_restore(socket) |> assign(:renaming, nil)}
  end

  def handle_event("save_rename", %{"id" => id, "title" => title}, socket) do
    scope = socket.assigns.current_scope

    with %{} = doc <- Documents.get_document(scope, id),
         {:ok, _} <- Documents.rename_document(scope, doc, %{"title" => title}) do
      {:noreply,
       socket
       |> assign(:renaming, nil)
       |> stream_insert(:documents, Documents.get_document(scope, id))}
    else
      _ -> {:noreply, maybe_restore(socket) |> assign(:renaming, nil)}
    end
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    {:noreply,
     assign(socket, :confirm_delete, Documents.get_document(socket.assigns.current_scope, id))}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with %{} = doc <- Documents.get_document(scope, id),
         {:ok, _} <- Documents.delete_document(scope, doc) do
      {:noreply,
       socket
       |> assign(:confirm_delete, nil)
       |> put_flash(:info, gettext("“%{title}” was deleted.", title: doc.title))
       |> stream_delete_by_dom_id(:documents, "documents-#{doc.id}")
       |> assign_ids(MapSet.delete(socket.assigns.ids, doc.id))}
    else
      _ ->
        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(:error, gettext("You can't do that."))}
    end
  end

  # Re-render the card that was being renamed, back to its normal state.
  defp maybe_restore(%{assigns: %{renaming: nil}} = socket), do: socket

  defp maybe_restore(socket) do
    id = socket.assigns.renaming
    socket = assign(socket, :renaming, nil)

    case Documents.get_document(socket.assigns.current_scope, id) do
      nil -> socket
      doc -> stream_insert(socket, :documents, doc)
    end
  end

  defp pages(%{current_version: %{page_count: n}}) when is_integer(n),
    do: ngettext("%{count} page", "%{count} pages", n)

  defp pages(_), do: "–"
end
