defmodule ReadoutWeb.UploadComponent do
  @moduledoc """
  Uploading from anywhere in the app: drop files on any page, press `U`, or
  use an Upload button (they dispatch `readout:pick-file`).

  Rendered once by the app shell. It owns the live upload, the full-window drop
  overlay and the tray that shows progress, then processing status, live.
  A LiveComponent because live uploads need a stateful owner and this one is
  shared by every page.

  Status updates arrive through `ReadoutWeb.Shell`, which forwards document
  events here with `send_update/2`.
  """
  use ReadoutWeb, :live_component

  alias Phoenix.LiveView.ColocatedHook
  alias Readout.Documents
  alias Readout.Documents.FileType
  alias ReadoutWeb.DocumentLabels

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(tracked: MapSet.new(), recent_count: 0, failures: [])
     |> stream_configure(:recent, dom_id: &"upload-recent-#{&1.id}")
     |> stream(:recent, [])
     |> allow_upload(:document,
       accept: FileType.accept(),
       max_entries: 10,
       max_file_size: Documents.max_upload_bytes(),
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  @impl true
  def update(%{document_event: {_event, id}}, socket) do
    if MapSet.member?(socket.assigns.tracked, id) do
      {:ok, refresh(socket, id)}
    else
      {:ok, socket}
    end
  end

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  defp handle_progress(:document, entry, socket) do
    if entry.done? do
      scope = socket.assigns.current_scope

      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, Documents.create_document(scope, %{path: path, filename: entry.client_name})}
        end)

      case result do
        {:ok, document} ->
          {:noreply,
           socket
           |> update(:tracked, &MapSet.put(&1, document.id))
           |> update(:recent_count, &(&1 + 1))
           |> stream_insert(:recent, item(document), at: 0)}

        {:error, reason} ->
          {:noreply, update(socket, :failures, &[{entry.client_name, reason} | Enum.take(&1, 4)])}
      end
    else
      {:noreply, socket}
    end
  end

  defp refresh(socket, id) do
    case Documents.get_document(socket.assigns.current_scope, id) do
      nil -> stream_delete_by_dom_id(socket, :recent, "upload-recent-#{id}")
      document -> stream_insert(socket, :recent, item(document))
    end
  end

  defp item(document) do
    version = document.latest_version

    %{
      id: document.id,
      title: document.title,
      status: version && version.status,
      error: version && version.error
    }
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :document, ref)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply,
     socket
     |> assign(tracked: MapSet.new(), recent_count: 0, failures: [])
     |> stream(:recent, [], reset: true)}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        visible?:
          assigns.uploads.document.entries != [] or assigns.recent_count > 0 or
            assigns.failures != [] or upload_errors(assigns.uploads.document) != []
      )

    ~H"""
    <div id={@id} phx-hook=".DropZone">
      <form id="upload-form" phx-change="validate" phx-submit="validate" phx-target={@myself}>
        <.live_file_input upload={@uploads.document} class="sr-only" tabindex="-1" />
      </form>

      <%!-- Full-window drop overlay, shown while files are dragged over the window. --%>
      <div
        id="drop-overlay"
        phx-drop-target={@uploads.document.ref}
        class={[
          "fixed inset-0 z-[90] hidden items-center justify-center bg-canvas/70 p-6 backdrop-blur-sm",
          "[[data-dragging]_&]:flex animate-fade-in"
        ]}
      >
        <div class="pointer-events-none flex w-full max-w-md flex-col items-center rounded-2xl border-2 border-dashed border-accent bg-surface/90 px-8 py-12 text-center shadow-xl transition-transform duration-(--duration-base) ease-(--ease-spring) [.phx-drop-target-active_&]:scale-[1.03]">
          <div class="mb-4 flex size-12 items-center justify-center rounded-xl bg-accent-soft text-accent-fg">
            <.icon name="hero-arrow-up-tray" class="size-6" />
          </div>
          <p class="text-lg font-semibold text-fg">{gettext("Drop to upload")}</p>
          <p class="mt-1 text-sm text-fg-muted">
            {gettext("PDF, Word, PowerPoint, Excel or CSV, up to %{size}.",
              size: DocumentLabels.size(Documents.max_upload_bytes())
            )}
          </p>
        </div>
      </div>

      <section
        :if={@visible?}
        id="upload-tray"
        aria-label={gettext("Uploads")}
        class="ui-enter fixed bottom-4 left-4 z-[60] w-[min(22rem,calc(100vw-2rem))] overflow-hidden rounded-xl border border-border bg-raised shadow-lg md:left-[calc(var(--sidebar-width)+1rem)] sidebar-collapsed:md:left-[calc(var(--sidebar-rail)+1rem)]"
      >
        <header class="flex items-center justify-between border-b border-border px-3 py-2">
          <h2 class="text-sm font-medium text-fg">{gettext("Uploads")}</h2>
          <button
            :if={@uploads.document.entries == []}
            id="clear-uploads"
            type="button"
            phx-click="clear"
            phx-target={@myself}
            class="cursor-pointer rounded-md px-1.5 py-0.5 text-xs text-fg-muted transition-colors hover:bg-hover hover:text-fg"
          >
            {gettext("Clear")}
          </button>
        </header>
        <ul class="max-h-72 divide-y divide-border overflow-y-auto">
          <li
            :for={entry <- @uploads.document.entries}
            id={"upload-entry-#{entry.ref}"}
            class="ui-enter px-3 py-2.5"
          >
            <div class="flex items-center gap-2">
              <.icon name="hero-document-arrow-up" class="size-4 text-fg-subtle" />
              <span class="min-w-0 flex-1 truncate text-sm text-fg">{entry.client_name}</span>
              <span class="text-xs text-fg-subtle tabular-nums">{entry.progress}%</span>
              <button
                type="button"
                phx-click="cancel"
                phx-value-ref={entry.ref}
                phx-target={@myself}
                class="cursor-pointer rounded p-0.5 text-fg-subtle hover:bg-hover hover:text-fg"
                aria-label={gettext("Cancel")}
              >
                <.icon name="hero-x-mark-mini" class="size-3.5" />
              </button>
            </div>
            <p
              :for={error <- upload_errors(@uploads.document, entry)}
              class="mt-1 text-xs text-danger-fg"
            >
              {DocumentLabels.upload_error(error)}
            </p>
            <.progress
              :if={upload_errors(@uploads.document, entry) == []}
              value={entry.progress}
              class="mt-2"
              label={entry.client_name}
            />
          </li>
          <li
            :for={error <- upload_errors(@uploads.document)}
            class="px-3 py-2.5 text-xs text-danger-fg"
          >
            {DocumentLabels.upload_error(error)}
          </li>
          <li :for={{name, reason} <- @failures} class="flex items-start gap-2 px-3 py-2.5">
            <.icon name="hero-exclamation-triangle-mini" class="mt-0.5 size-4 text-danger" />
            <div class="min-w-0">
              <p class="truncate text-sm text-fg">{name}</p>
              <p class="text-xs text-danger-fg">{DocumentLabels.upload_error(reason)}</p>
            </div>
          </li>
        </ul>
        <ul
          id="upload-recent"
          phx-update="stream"
          class="divide-y divide-border border-t border-border empty:hidden"
        >
          <li :for={{dom_id, item} <- @streams.recent} id={dom_id} class="ui-enter">
            <.link
              navigate={~p"/documents/#{item.id}"}
              class="flex items-center gap-2 px-3 py-2.5 transition-colors hover:bg-hover"
            >
              <.status_icon status={item.status} />
              <span class="min-w-0 flex-1 truncate text-sm text-fg">{item.title}</span>
              <span class={[
                "text-xs",
                item.status == :failed && "text-danger-fg",
                item.status != :failed && "text-fg-subtle"
              ]}>
                {item.status && DocumentLabels.status_label(item.status)}
              </span>
            </.link>
          </li>
        </ul>
      </section>
      <script :type={ColocatedHook} name=".DropZone">
        // Flags <html data-dragging> while files are dragged over the window so the
        // drop overlay (the real phx-drop-target) shows up under the pointer.
        export default {
          mounted() {
            const html = document.documentElement
            let depth = 0
            const hasFiles = e => Array.from(e.dataTransfer?.types || []).includes("Files")
            const stop = () => { depth = 0; delete html.dataset.dragging }
            this.onEnter = e => { if (hasFiles(e)) { depth++; html.dataset.dragging = "" } }
            this.onLeave = e => { if (hasFiles(e) && --depth <= 0) stop() }
            this.onStop = stop
            window.addEventListener("dragenter", this.onEnter)
            window.addEventListener("dragleave", this.onLeave)
            window.addEventListener("drop", this.onStop)
            window.addEventListener("dragend", this.onStop)
            // Upload buttons anywhere dispatch this to open the file picker.
            this.onPick = () => this.el.querySelector("input[type=file]")?.click()
            window.addEventListener("readout:pick-file", this.onPick)
          },
          destroyed() {
            window.removeEventListener("dragenter", this.onEnter)
            window.removeEventListener("dragleave", this.onLeave)
            window.removeEventListener("drop", this.onStop)
            window.removeEventListener("dragend", this.onStop)
            window.removeEventListener("readout:pick-file", this.onPick)
            this.onStop()
          }
        }
      </script>
    </div>
    """
  end

  attr :status, :atom, default: nil

  defp status_icon(assigns) do
    ~H"""
    <span class="flex size-4 items-center justify-center">
      <%= case @status do %>
        <% :ready -> %>
          <.icon name="hero-check-circle-mini" class="size-4 text-success" />
        <% :failed -> %>
          <.icon name="hero-exclamation-circle-mini" class="size-4 text-danger" />
        <% _ -> %>
          <span class="size-2 animate-pulse-dot rounded-full bg-accent text-accent" />
      <% end %>
    </span>
    """
  end
end
