defmodule ReadoutWeb.SettingsLive.Audit do
  @moduledoc "Settings → Audit log (owners and admins). New entries appear live."
  use ReadoutWeb, :live_view

  on_mount {ReadoutWeb.UserAuth, {:can, :view_audit_log}}

  alias Readout.{Accounts, Audit}
  alias Readout.Accounts.User
  alias ReadoutWeb.AuditLabels

  @page_size 50

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:settings}>
      <:crumb navigate={~p"/settings/profile"}>{gettext("Settings")}</:crumb>
      <:crumb>{gettext("Audit log")}</:crumb>

      <Layouts.settings_nav current_scope={@current_scope} active={:audit} />

      <div class="mb-4">
        <h2 class="text-lg font-semibold text-fg">{gettext("Audit log")}</h2>
        <p class="text-sm text-fg-muted">
          {gettext("Who did what, and when. Entries are kept even if people leave.")}
        </p>
      </div>

      <.form
        for={@filter_form}
        id="audit-filters"
        phx-change="filter"
        phx-submit="filter"
        class="mb-3 flex flex-wrap items-center gap-2"
      >
        <.search_input
          id="audit-search"
          name="query"
          value={@filters["query"]}
          placeholder={gettext("Search people")}
          shortcut
          phx-debounce="200"
          class="w-full sm:w-64"
        />
        <.input
          type="select"
          name="action"
          id="audit-action-filter"
          value={@filters["action"]}
          prompt={gettext("All activity")}
          options={AuditLabels.categories()}
          wrapper_class="w-44"
        />
        <.input
          type="select"
          name="actor_id"
          id="audit-actor-filter"
          value={@filters["actor_id"]}
          prompt={gettext("Anyone")}
          options={for u <- @people, do: {User.display_name(u), u.id}}
          wrapper_class="w-48"
        />
      </.form>

      <div class="rounded-lg border border-border bg-surface shadow-xs">
        <ol id="audit-events" phx-update="stream" class="divide-y divide-border">
          <li id="audit-events-empty" class="hidden only:block">
            <.empty_state icon="hero-shield-check" title={gettext("Nothing here yet")}>
              {gettext("Invitations, role changes and sharing activity will show up here.")}
            </.empty_state>
          </li>
          <li
            :for={{id, event} <- @streams.events}
            id={id}
            class="ui-enter-row flex items-center gap-3 px-4 py-3"
          >
            <span class="flex size-7 shrink-0 items-center justify-center rounded-md border border-border bg-inset text-fg-subtle">
              <.icon name={AuditLabels.icon(event)} class="size-3.5" />
            </span>
            <p class="min-w-0 flex-1 text-sm text-fg">{AuditLabels.describe(event)}</p>
            <.relative_time
              at={event.inserted_at}
              scope={@current_scope}
              class="shrink-0 text-xs text-fg-subtle"
            />
          </li>
        </ol>
      </div>

      <div :if={@more?} class="mt-4 flex justify-center">
        <.button id="load-more" variant="ghost" phx-click="load_more">
          {gettext("Load older entries")}
        </.button>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Audit.subscribe(scope)

    {:ok,
     socket
     |> assign(:page_title, gettext("Audit log"))
     |> assign(:people, Accounts.list_members(scope))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters =
      Map.merge(
        %{"query" => "", "action" => "", "actor_id" => ""},
        Map.take(params, ["query", "action", "actor_id"])
      )

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:filter_form, to_form(filters))
     |> load(reset: true)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    filters =
      params
      |> Map.take(["query", "action", "actor_id"])
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/settings/audit?#{filters}", replace: true)}
  end

  def handle_event("load_more", _params, socket) do
    {:noreply, load(socket, before: socket.assigns.cursor)}
  end

  @impl true
  def handle_info({:audit_event, event}, socket) do
    if Enum.all?(Map.values(socket.assigns.filters), &(&1 == "")) do
      {:noreply, stream_insert(socket, :events, event, at: 0)}
    else
      {:noreply, socket}
    end
  end

  defp load(socket, opts) do
    filters = socket.assigns.filters

    {:ok, events} =
      Audit.list_events(socket.assigns.current_scope,
        action: filters["action"],
        actor_id: filters["actor_id"],
        query: filters["query"],
        before: opts[:before],
        limit: @page_size + 1
      )

    {page, rest} = Enum.split(events, @page_size)
    cursor = page |> List.last() |> then(&(&1 && &1.inserted_at))

    socket
    |> assign(:more?, rest != [])
    |> assign(:cursor, cursor)
    |> stream(:events, page, reset: Keyword.get(opts, :reset, false))
  end
end
