defmodule ReadoutWeb.DocumentLive.Show do
  @moduledoc """
  A document: the internal viewer, its versions, who can see it, and actions
  (rename, new version, download, delete). Processing status updates live.
  """
  use ReadoutWeb, :live_view

  import ReadoutWeb.DocumentComponents
  import ReadoutWeb.ViewerComponents

  alias Readout.{Accounts, Documents, Policy}
  alias Readout.Accounts.User
  alias Readout.Documents.{FileType, Pdf, Version}
  alias ReadoutWeb.DocumentLabels

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:documents} width="wide">
      <:crumb navigate={~p"/documents"}>{gettext("Documents")}</:crumb>
      <:crumb>{@document.title}</:crumb>
      <:actions>
        <form :if={@can_edit} id="version-upload-form" phx-change="validate_version">
          <.live_file_input upload={@uploads.version} class="sr-only" tabindex="-1" />
        </form>
        <.button
          :if={@can_edit}
          id="new-version-button"
          size="sm"
          icon="hero-arrow-up-tray-mini"
          for={@uploads.version.ref}
        >
          {gettext("New version")}
        </.button>
        <.dropdown id="document-actions">
          <:trigger>
            <.icon_button icon="hero-ellipsis-horizontal-mini" label={gettext("More actions")} />
          </:trigger>
          <:item
            :if={@document.current_version}
            icon="hero-arrow-down-tray-mini"
            href={download_url(@document, @document.current_version, "pdf")}
          >
            {gettext("Download PDF")}
          </:item>
          <:item
            :if={@document.current_version && Version.office?(@document.current_version)}
            icon="hero-document-arrow-down-mini"
            href={download_url(@document, @document.current_version, "original")}
          >
            {gettext("Download original (%{format})",
              format: DocumentLabels.format_label(@document.current_version.format)
            )}
          </:item>
          <:item :if={@can_edit} icon="hero-pencil-square-mini" phx-click="start_rename">
            {gettext("Rename")}
          </:item>
          <:item icon="hero-users-mini" phx-click={open_dialog("access-sheet")}>
            {if @can_manage, do: gettext("Share with people"), else: gettext("Who can see this")}
          </:item>
          <:item :if={@can_manage} separator />
          <:item
            :if={@can_manage}
            icon="hero-trash-mini"
            danger
            phx-click={open_dialog("delete-document-dialog")}
          >
            {gettext("Delete")}
          </:item>
        </.dropdown>
      </:actions>

      <header class="mb-6">
        <%= if @renaming do %>
          <.form for={@title_form} id="title-form" phx-submit="save_title" phx-change="validate_title">
            <input
              id="title-input"
              type="text"
              name={@title_form[:title].name}
              value={@title_form[:title].value}
              maxlength="200"
              aria-label={gettext("Title")}
              phx-mounted={JS.focus() |> JS.dispatch("readout:select")}
              phx-keydown="cancel_rename"
              phx-key="Escape"
              class="-mx-1.5 w-full rounded-md border border-accent bg-surface px-1.5 text-2xl font-semibold text-fg ring-3 ring-accent/20 outline-none"
            />
          </.form>
        <% else %>
          <h1
            id="document-title"
            class={[
              "-mx-1.5 truncate rounded-md px-1.5 text-2xl font-semibold text-fg",
              @can_edit && "cursor-text transition-colors hover:bg-hover"
            ]}
            phx-click={@can_edit && "start_rename"}
            title={@can_edit && gettext("Click to rename")}
          >
            {@document.title}
          </h1>
        <% end %>
        <div class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1.5 text-sm text-fg-muted">
          <.badge :if={@document.visibility == :restricted} tone="neutral">
            <.icon name="hero-lock-closed-micro" class="size-3" />
            {DocumentLabels.visibility_label(:restricted)}
          </.badge>
          <span class="flex items-center gap-1.5">
            <.avatar
              name={User.display_name(@document.owner)}
              color={@document.owner.avatar_color}
              size="xs"
            />
            {User.display_name(@document.owner)}
          </span>
          <span :if={@document.current_version} class="tabular-nums">
            {ngettext("%{count} page", "%{count} pages", @document.current_version.page_count)}
          </span>
          <span>
            {gettext("Updated")} <.relative_time at={@document.updated_at} scope={@current_scope} />
          </span>
          <.status_badge version={@document.latest_version} />
        </div>
      </header>

      <div
        :for={entry <- @uploads.version.entries}
        id={"version-entry-#{entry.ref}"}
        class="ui-enter mb-4 flex items-center gap-3 rounded-lg border border-border bg-surface px-4 py-3"
      >
        <.icon name="hero-document-arrow-up" class="size-4 text-fg-subtle" />
        <span class="min-w-0 flex-1 truncate text-sm">{entry.client_name}</span>
        <span
          :for={error <- upload_errors(@uploads.version, entry)}
          class="text-xs text-danger-fg"
        >
          {DocumentLabels.upload_error(error)}
        </span>
        <.progress
          :if={upload_errors(@uploads.version, entry) == []}
          value={entry.progress}
          class="w-32"
        />
        <button
          type="button"
          phx-click="cancel_version"
          phx-value-ref={entry.ref}
          class="cursor-pointer rounded p-0.5 text-fg-subtle hover:bg-hover hover:text-fg"
          aria-label={gettext("Cancel")}
        >
          <.icon name="hero-x-mark-mini" class="size-4" />
        </button>
      </div>

      <.tabs id="document-tabs" class="mb-6">
        <:tab patch={~p"/documents/#{@document}"} active={@live_action == :show} id="tab-viewer">
          {gettext("Document")}
        </:tab>
        <:tab
          patch={~p"/documents/#{@document}/versions"}
          active={@live_action == :versions}
          count={length(@document.versions)}
          id="tab-versions"
        >
          {gettext("Versions")}
        </:tab>
      </.tabs>

      <%= if @live_action == :versions do %>
        <.versions document={@document} scope={@current_scope} can_edit={@can_edit} />
      <% else %>
        <%= cond do %>
          <% @document.current_version -> %>
            <.viewer
              id="viewer"
              pages={@streams.pages}
              thumbs={@streams.thumbs}
              page_count={@document.current_version.page_count}
              src={&page_url(@document, @document.current_version, &1.number, Pdf.view_width())}
              thumb_src={
                &page_url(@document, @document.current_version, &1.number, Pdf.thumb_width())
              }
            />
          <% @document.latest_version && @document.latest_version.status == :failed -> %>
            <div class="rounded-xl border border-border bg-surface">
              <.empty_state
                id="document-failed"
                icon="hero-exclamation-triangle"
                title={gettext("This document couldn't be processed")}
              >
                {DocumentLabels.error_message(@document.latest_version.error)}
                <:actions :if={@can_edit}>
                  <.button
                    id="retry-processing"
                    phx-click="retry"
                    phx-value-id={@document.latest_version.id}
                  >
                    {gettext("Try again")}
                  </.button>
                </:actions>
              </.empty_state>
            </div>
          <% true -> %>
            <div id="document-processing" class="mx-auto max-w-3xl space-y-4">
              <p class="flex items-center justify-center gap-2 text-sm text-fg-muted">
                <span class="size-2 animate-pulse-dot rounded-full bg-accent text-accent" />
                {gettext("Preparing pages… this usually takes a few seconds.")}
              </p>
              <.skeleton :for={_ <- 1..2} class="aspect-[1/1.414] w-full rounded-md" />
            </div>
        <% end %>
      <% end %>

      <.access_sheet
        document={@document}
        scope={@current_scope}
        can_manage={@can_manage}
        candidates={@candidates}
        member_form={@member_form}
      />

      <.dialog
        :if={@can_manage}
        id="delete-document-dialog"
        title={gettext("Delete “%{title}”?", title: @document.title)}
      >
        <p class="text-sm text-fg-muted">
          {gettext("Its files and links stop working right away. Reading history is kept.")}
        </p>
        <:footer>
          <.button phx-click={close_dialog("delete-document-dialog")}>{gettext("Cancel")}</.button>
          <.button id="confirm-delete-document" variant="danger" phx-click="delete">
            {gettext("Delete")}
          </.button>
        </:footer>
      </.dialog>
    </Layouts.app>
    """
  end

  attr :document, :any, required: true
  attr :scope, :any, required: true
  attr :can_edit, :boolean, required: true

  defp versions(assigns) do
    ~H"""
    <.table id="versions" rows={@document.versions} row_id={&"version-#{&1.id}"}>
      <:col :let={v} label={gettext("Version")}>
        <span class="flex items-center gap-2 font-medium text-fg tabular-nums">
          v{v.number}
          <.badge :if={v.id == @document.current_version_id} tone="accent">
            {gettext("Current")}
          </.badge>
        </span>
      </:col>
      <:col :let={v} label={gettext("File")}>
        <span class="block max-w-64 truncate text-fg" title={v.original_filename}>
          {v.original_filename}
        </span>
        <span class="text-xs text-fg-subtle">
          {DocumentLabels.format_label(v.format)} · {DocumentLabels.size(v.byte_size)}
        </span>
      </:col>
      <:col :let={v} label={gettext("Pages")} numeric>{v.page_count || "–"}</:col>
      <:col :let={v} label={gettext("Uploaded by")} class="text-fg-muted">
        {v.uploaded_by && User.display_name(v.uploaded_by)}
      </:col>
      <:col :let={v} label={gettext("Uploaded")} class="text-fg-muted">
        <.relative_time at={v.inserted_at} scope={@scope} />
      </:col>
      <:col :let={v} label={gettext("Status")}>
        <%= if v.status == :ready do %>
          <.badge tone="success" dot>{DocumentLabels.status_label(:ready)}</.badge>
        <% else %>
          <.status_badge version={v} />
          <p :if={v.status == :failed} class="mt-1 text-xs text-fg-subtle">
            {DocumentLabels.error_message(v.error)}
          </p>
        <% end %>
      </:col>
      <:action :let={v}>
        <.button
          :if={v.status == :failed and @can_edit}
          size="xs"
          variant="ghost"
          phx-click="retry"
          phx-value-id={v.id}
        >
          {gettext("Try again")}
        </.button>
        <.icon_button
          icon="hero-arrow-down-tray-mini"
          label={gettext("Download original")}
          href={download_url(@document, v, "original")}
          size="xs"
        />
      </:action>
    </.table>
    """
  end

  attr :document, :any, required: true
  attr :scope, :any, required: true
  attr :can_manage, :boolean, required: true
  attr :candidates, :list, required: true
  attr :member_form, :any, required: true

  defp access_sheet(assigns) do
    ~H"""
    <.sheet
      id="access-sheet"
      title={gettext("Who can see this")}
      description={gettext("Links you share are separate: anyone with a link sees what it allows.")}
    >
      <div class="space-y-6">
        <section>
          <h3 class="mb-2 text-sm font-medium text-fg">{gettext("Visibility")}</h3>
          <div class="space-y-1.5" role="radiogroup">
            <button
              :for={vis <- [:workspace, :restricted]}
              id={"visibility-#{vis}"}
              type="button"
              role="radio"
              aria-checked={to_string(@document.visibility == vis)}
              disabled={!@can_manage}
              phx-click="set_visibility"
              phx-value-visibility={vis}
              class={[
                "flex w-full items-start gap-3 rounded-lg border p-3 text-left transition-colors",
                @can_manage && "cursor-pointer hover:bg-hover/50",
                if(@document.visibility == vis,
                  do: "border-accent bg-accent-soft/50",
                  else: "border-border"
                )
              ]}
            >
              <.icon
                name={if(vis == :workspace, do: "hero-building-office-2", else: "hero-lock-closed")}
                class="mt-0.5 size-4 text-fg-muted"
              />
              <span>
                <span class="block text-sm font-medium text-fg">
                  {DocumentLabels.visibility_label(vis)}
                </span>
                <span class="block text-xs text-fg-muted">
                  {if vis == :workspace,
                    do: gettext("Everyone in the workspace can see it."),
                    else: gettext("Only the owner, the people below and admins.")}
                </span>
              </span>
            </button>
          </div>
        </section>

        <section>
          <h3 class="mb-2 text-sm font-medium text-fg">{gettext("People")}</h3>
          <ul id="document-people" class="divide-y divide-border rounded-lg border border-border">
            <li class="flex items-center gap-3 px-3 py-2.5">
              <.avatar
                name={User.display_name(@document.owner)}
                color={@document.owner.avatar_color}
                size="sm"
              />
              <span class="min-w-0 flex-1 truncate text-sm">{User.display_name(@document.owner)}</span>
              <span class="text-xs text-fg-subtle">{gettext("Owner")}</span>
            </li>
            <li
              :for={member <- @document.members}
              id={"document-member-#{member.user_id}"}
              class="flex items-center gap-3 px-3 py-2.5"
            >
              <.avatar
                name={User.display_name(member.user)}
                color={member.user.avatar_color}
                size="sm"
              />
              <span class="min-w-0 flex-1 truncate text-sm">{User.display_name(member.user)}</span>
              <span class="text-xs text-fg-subtle">{DocumentLabels.member_role_label(member.role)}</span>
              <.icon_button
                :if={@can_manage}
                icon="hero-x-mark-mini"
                label={gettext("Remove %{name}", name: User.display_name(member.user))}
                size="xs"
                phx-click="remove_member"
                phx-value-id={member.user_id}
              />
            </li>
          </ul>

          <.form
            :if={@can_manage and @candidates != []}
            for={@member_form}
            id="add-member-form"
            phx-submit="add_member"
            class="mt-3 flex items-end gap-2"
          >
            <.input
              field={@member_form[:user_id]}
              type="select"
              label={gettext("Add a person")}
              prompt={gettext("Choose a person")}
              options={for u <- @candidates, do: {User.display_name(u), u.id}}
              wrapper_class="min-w-0 flex-1"
            />
            <.input
              field={@member_form[:role]}
              type="select"
              options={[
                {DocumentLabels.member_role_label(:viewer), "viewer"},
                {DocumentLabels.member_role_label(:editor), "editor"}
              ]}
              wrapper_class="w-28"
            />
            <.button type="submit" variant="primary">{gettext("Add")}</.button>
          </.form>
          <p class="mt-2 text-xs text-fg-subtle">
            {gettext("Editors manage links and versions. Viewers see the document and its analytics.")}
          </p>
        </section>
      </div>
    </.sheet>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Documents.get_document(socket.assigns.current_scope, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That document doesn't exist or you can't see it."))
         |> push_navigate(to: ~p"/documents")}

      document ->
        {:ok,
         socket
         |> assign(renaming: false, loaded_version_id: nil)
         |> assign(:member_form, to_form(%{"user_id" => "", "role" => "viewer"}, as: "member"))
         |> stream_configure(:pages, dom_id: &"page-#{&1.number}")
         |> stream_configure(:thumbs, dom_id: &"thumb-#{&1.number}")
         |> allow_upload(:version,
           accept: FileType.accept(),
           max_entries: 1,
           max_file_size: Documents.max_upload_bytes(),
           auto_upload: true,
           progress: &handle_progress/3
         )
         |> assign_document(document)}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp assign_document(socket, document) do
    scope = socket.assigns.current_scope
    member_ids = MapSet.new(document.members, & &1.user_id)

    candidates =
      if Policy.can?(scope, :manage_document, document) do
        scope
        |> Accounts.list_members(status: "active")
        |> Enum.reject(&(&1.id == document.owner_id or MapSet.member?(member_ids, &1.id)))
      else
        []
      end

    socket
    |> assign(:document, document)
    |> assign(:page_title, document.title)
    |> assign(:can_edit, Policy.can?(scope, :edit_document, document))
    |> assign(:can_manage, Policy.can?(scope, :manage_document, document))
    |> assign(:candidates, candidates)
    |> assign(:title_form, to_form(Documents.change_title(document)))
    |> load_pages()
  end

  # Pages only reload when the current version changes.
  defp load_pages(%{assigns: %{document: %{current_version: nil}}} = socket), do: socket

  defp load_pages(%{assigns: %{document: %{current_version: v}, loaded_version_id: id}} = socket)
       when v.id == id,
       do: socket

  defp load_pages(%{assigns: %{document: %{current_version: version}}} = socket) do
    pages = Documents.list_pages(version)

    socket
    |> assign(:loaded_version_id, version.id)
    |> stream(:pages, pages, reset: true)
    |> stream(:thumbs, pages, reset: true)
  end

  defp reload(socket) do
    case Documents.get_document(socket.assigns.current_scope, socket.assigns.document.id) do
      nil ->
        socket
        |> put_flash(:info, gettext("This document is no longer available."))
        |> push_navigate(to: ~p"/documents")

      document ->
        assign_document(socket, document)
    end
  end

  @doc false
  def handle_document_event(_event, id, socket) do
    if id == socket.assigns.document.id, do: reload(socket), else: socket
  end

  ## Uploading a new version

  defp handle_progress(:version, entry, socket) do
    if entry.done? do
      scope = socket.assigns.current_scope
      document = socket.assigns.document

      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok,
           Documents.add_version(scope, document, %{path: path, filename: entry.client_name})}
        end)

      case result do
        {:ok, version} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             gettext("Version %{number} uploaded. Processing…", number: version.number)
           )
           |> reload()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, DocumentLabels.upload_error(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("validate_version", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_version", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :version, ref)}
  end

  ## Renaming

  def handle_event("start_rename", _params, socket) do
    {:noreply, assign(socket, :renaming, socket.assigns.can_edit)}
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply,
     assign(socket,
       renaming: false,
       title_form: to_form(Documents.change_title(socket.assigns.document))
     )}
  end

  def handle_event("validate_title", %{"document" => params}, socket) do
    form =
      socket.assigns.document
      |> Documents.change_title(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :title_form, form)}
  end

  def handle_event("save_title", %{"document" => params}, socket) do
    case Documents.rename_document(socket.assigns.current_scope, socket.assigns.document, params) do
      {:ok, _} -> {:noreply, socket |> assign(:renaming, false) |> reload()}
      {:error, %Ecto.Changeset{} = cs} -> {:noreply, assign(socket, :title_form, to_form(cs))}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("You can't do that."))}
    end
  end

  ## Processing

  def handle_event("retry", %{"id" => id}, socket) do
    document = socket.assigns.document

    with %Version{} = version <- Documents.get_version(document, id),
         {:ok, _} <- Documents.retry_version(socket.assigns.current_scope, document, version) do
      {:noreply, reload(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("You can't do that."))}
    end
  end

  ## Access

  def handle_event("set_visibility", %{"visibility" => vis}, socket)
      when vis in ["workspace", "restricted"] do
    case Documents.update_visibility(socket.assigns.current_scope, socket.assigns.document, vis) do
      {:ok, _} -> {:noreply, reload(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("You can't do that."))}
    end
  end

  def handle_event("add_member", %{"member" => %{"user_id" => user_id, "role" => role}}, socket)
      when role in ["viewer", "editor"] do
    with %User{} = user <- Enum.find(socket.assigns.candidates, &(&1.id == user_id)),
         {:ok, _} <-
           Documents.put_member(
             socket.assigns.current_scope,
             socket.assigns.document,
             user,
             String.to_existing_atom(role)
           ) do
      {:noreply, reload(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Choose a person first."))}
    end
  end

  def handle_event("remove_member", %{"id" => user_id}, socket) do
    case Documents.remove_member(socket.assigns.current_scope, socket.assigns.document, user_id) do
      :ok -> {:noreply, reload(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("You can't do that."))}
    end
  end

  ## Deleting

  def handle_event("delete", _params, socket) do
    case Documents.delete_document(socket.assigns.current_scope, socket.assigns.document) do
      {:ok, doc} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("“%{title}” was deleted.", title: doc.title))
         |> push_navigate(to: ~p"/documents")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("You can't do that."))}
    end
  end
end
