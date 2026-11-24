defmodule ReadoutWeb.AnalyticsLive do
  @moduledoc """
  Workspace analytics: totals, who is reading right now across every
  document, the most-read documents, and the live Activity feed. Everything is
  limited to the documents the person can see, and updates without a refresh.
  """
  use ReadoutWeb, :live_view

  alias Readout.{Analytics, GeoIP}
  alias ReadoutWeb.Presence

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:analytics} width="wide">
      <:crumb>{gettext("Analytics")}</:crumb>

      <.header class="mb-6">
        {gettext("Analytics")}
        <:subtitle>{gettext("Who is reading what, live.")}</:subtitle>
        <:actions>
          <.segmented id="workspace-range">
            <:item
              :for={
                {value, label} <- [
                  {"7d", gettext("7 days")},
                  {"30d", gettext("30 days")},
                  {"all", gettext("All time")}
                ]
              }
              patch={~p"/analytics?#{%{range: value}}"}
              active={@range == value}
              label={label}
            />
          </.segmented>
        </:actions>
      </.header>

      <div class="mb-6 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <.stat_tile
          id="ws-visits"
          label={gettext("Visits")}
          value={Format.number(@overview.totals.visits)}
          delta={@overview.deltas[:visits]}
          icon="hero-eye"
        />
        <.stat_tile
          id="ws-unique"
          label={gettext("Unique viewers")}
          value={Format.number(@overview.totals.unique)}
          delta={@overview.deltas[:unique]}
          icon="hero-users"
        />
        <.stat_tile
          id="ws-time"
          label={gettext("Average time")}
          value={Format.duration(div(@overview.totals.avg_ms, 1000))}
          icon="hero-clock"
        />
        <.stat_tile
          id="ws-reading"
          label={gettext("Reading now")}
          value={length(@readers)}
          icon="hero-signal"
        />
      </div>

      <div class="grid gap-6 xl:grid-cols-3">
        <div class="space-y-6 xl:col-span-1">
          <.card id="ws-reading-now" title={gettext("Reading now")}>
            <p :if={@readers == []} class="text-sm text-fg-subtle">
              {gettext("No one is reading right now.")}
            </p>
            <ul class="space-y-2">
              <li :for={r <- @readers} id={"ws-reader-#{r.visit_id}"} class="ui-enter">
                <.link
                  navigate={~p"/documents/#{r.document_id}/analytics"}
                  class="block rounded-lg border border-border px-3 py-2 transition-colors hover:bg-hover"
                >
                  <p class="flex items-center gap-2 truncate text-sm font-medium text-fg">
                    <span class="size-1.5 shrink-0 animate-pulse-dot rounded-full bg-success text-success" />
                    {reader_name(r, @locale)}
                  </p>
                  <p class="mt-0.5 truncate text-xs text-fg-muted">
                    {@titles[r.document_id]} · {if r.page,
                      do: gettext("p. %{page}/%{count}", page: r.page, count: r.page_count),
                      else: "–"}
                  </p>
                </.link>
              </li>
            </ul>
          </.card>

          <.card id="top-documents" title={gettext("Most read")}>
            <p :if={@overview.top_documents == []} class="text-sm text-fg-subtle">
              {gettext("No visits in this period.")}
            </p>
            <.bar_list
              :if={@overview.top_documents != []}
              id="top-documents-list"
              items={
                for d <- @overview.top_documents,
                    do: %{
                      label: d.title,
                      value: d.visits,
                      display: ngettext("%{count} visit", "%{count} visits", d.visits)
                    }
              }
            />
          </.card>
        </div>

        <section class="xl:col-span-2">
          <h2 class="mb-3 text-md font-semibold text-fg">{gettext("Activity")}</h2>
          <ol
            id="activity"
            phx-update="stream"
            class="divide-y divide-border rounded-lg border border-border bg-surface shadow-xs"
          >
            <li id="activity-empty" class="hidden only:block">
              <.empty_state icon="hero-chart-bar" title={gettext("No reading activity yet")}>
                {gettext(
                  "Share a document with a link. Visits and time per page appear here as people read."
                )}
              </.empty_state>
            </li>
            <li :for={{id, v} <- @streams.activity} id={id} class="ui-enter-row">
              <.link
                navigate={~p"/documents/#{v.document_id}/analytics?#{%{visit: v.id}}"}
                class="flex items-center gap-3 px-4 py-3 transition-colors hover:bg-hover/50"
              >
                <.avatar
                  name={viewer_name(v, @locale)}
                  color={if(v.email, do: "teal", else: "slate")}
                  size="sm"
                />
                <div class="min-w-0 flex-1">
                  <p class="truncate text-sm text-fg">
                    {gettext("%{viewer} opened «%{title}»",
                      viewer: viewer_name(v, @locale),
                      title: v.document.title
                    )}
                  </p>
                  <p class="truncate text-xs text-fg-subtle">
                    {gettext("via «%{link}»", link: v.link.name)} · {gettext(
                      "%{pages}/%{count} pages", pages: v.pages_viewed, count: v.page_count || "?")} · {Format.duration(
                      div(v.duration_ms, 1000)
                    )}
                  </p>
                </div>
                <.badge :if={MapSet.member?(@live_ids, v.id)} tone="success" pulse>
                  {gettext("Live")}
                </.badge>
                <.relative_time
                  at={v.started_at}
                  scope={@current_scope}
                  class="shrink-0 text-xs text-fg-subtle"
                />
              </.link>
            </li>
          </ol>
        </section>
      </div>

      <p class="mt-8 text-xs text-fg-faint">
        {gettext("Locations are approximate, from the viewer's IP address.")}
        <a
          :if={Readout.GeoIP.database()}
          href="https://db-ip.com"
          class="underline-offset-2 hover:underline"
          rel="noopener noreferrer"
          target="_blank"
        >
          {gettext("IP geolocation by DB-IP")}
        </a>
      </p>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Analytics.subscribe(socket.assigns.current_scope)
      Phoenix.PubSub.subscribe(Readout.PubSub, Presence.workspace_topic())
    end

    {:ok,
     socket
     |> assign(:page_title, gettext("Analytics"))
     |> assign(:refresh_timer, nil)
     |> stream_configure(:activity, dom_id: &"activity-#{&1.id}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    range = if params["range"] in ["7d", "30d", "all"], do: params["range"], else: "7d"

    {:noreply,
     socket
     |> assign(:range, range)
     |> load()
     |> load_readers()}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    overview = Analytics.workspace_overview(scope, range: socket.assigns.range)

    titles =
      scope
      |> Readout.Documents.list_documents()
      |> Map.new(&{&1.id, &1.title})

    socket
    |> assign(overview: overview, titles: titles)
    |> stream(:activity, Analytics.recent_activity(scope, overview.document_ids), reset: true)
  end

  defp load_readers(socket) do
    ids = socket.assigns.overview.document_ids

    readers =
      Presence.all_readers()
      |> Enum.filter(&MapSet.member?(ids, &1.document_id))
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})

    assign(socket, readers: readers, live_ids: MapSet.new(readers, & &1.visit_id))
  end

  @impl true
  def handle_info({:analytics, event, %{visit_id: id}}, socket) do
    socket =
      case Analytics.feed_visit(socket.assigns.overview.document_ids, id) do
        nil -> socket
        visit when event == :visit_started -> stream_insert(socket, :activity, visit, at: 0)
        visit -> stream_insert(socket, :activity, visit)
      end

    {:noreply, schedule_refresh(socket)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, load_readers(socket)}
  end

  def handle_info(:refresh, socket) do
    overview =
      Analytics.workspace_overview(socket.assigns.current_scope, range: socket.assigns.range)

    {:noreply, assign(socket, overview: overview, refresh_timer: nil)}
  end

  @doc false
  # New or changed documents (shared with this person, deleted...) change
  # what the feed may show.
  def handle_document_event(_event, _id, socket), do: socket |> load() |> load_readers()

  defp schedule_refresh(%{assigns: %{refresh_timer: nil}} = socket),
    do: assign(socket, :refresh_timer, Process.send_after(self(), :refresh, 2000))

  defp schedule_refresh(socket), do: socket

  defp location(v, locale),
    do:
      GeoIP.label(%{country: Map.get(v, :country) || %{}, city: Map.get(v, :city) || %{}}, locale)

  defp reader_name(%{email: email}, _locale) when is_binary(email), do: email
  defp reader_name(r, locale), do: anonymous(location(r, locale))

  defp viewer_name(%{email: email}, _locale) when is_binary(email), do: email
  defp viewer_name(v, locale), do: anonymous(location(v, locale))

  defp anonymous(nil), do: gettext("Anonymous")
  defp anonymous(place), do: gettext("Anonymous · %{place}", place: place)
end
