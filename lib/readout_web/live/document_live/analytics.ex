defmodule ReadoutWeb.DocumentLive.Analytics do
  @moduledoc """
  A document's analytics: who is reading now (live, with their page), stat
  tiles, visits over time, time per page (where attention holds and where
  readers drop off), per-link breakdown, viewers and visits, and a visit's
  page-by-page timeline. Everything updates live.
  """
  use ReadoutWeb, :live_view

  alias Readout.Policy

  alias Readout.{Analytics, Documents, GeoIP}
  alias ReadoutWeb.Presence

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:documents} width="wide">
      <:crumb navigate={~p"/documents"}>{gettext("Documents")}</:crumb>
      <:crumb navigate={~p"/documents/#{@document}"}>{@document.title}</:crumb>
      <:crumb>{gettext("Analytics")}</:crumb>

      <header class="mb-6">
        <h1 class="truncate text-2xl font-semibold text-fg">{@document.title}</h1>
      </header>

      <.tabs id="document-tabs" class="mb-6">
        <:tab navigate={~p"/documents/#{@document}"} id="tab-viewer">{gettext("Document")}</:tab>
        <:tab navigate={~p"/documents/#{@document}/links"} id="tab-links">{gettext("Links")}</:tab>
        <:tab navigate={~p"/documents/#{@document}/versions"} id="tab-versions">
          {gettext("Versions")}
        </:tab>
        <:tab patch={~p"/documents/#{@document}/analytics"} active id="tab-analytics">
          {gettext("Analytics")}
        </:tab>
      </.tabs>

      <div class="mb-6 flex flex-wrap items-center justify-between gap-3">
        <.segmented id="analytics-range">
          <:item
            :for={{value, label} <- ranges()}
            patch={~p"/documents/#{@document}/analytics?#{params(@params, range: value)}"}
            active={@params["range"] == value}
            label={label}
          />
        </.segmented>
        <.form for={%{}} id="version-filter" phx-change="version">
          <.input
            type="select"
            name="version"
            id="analytics-version"
            value={@params["version"]}
            prompt={gettext("All versions")}
            options={for v <- @document.versions, v.status == :ready, do: {"v#{v.number}", v.id}}
            wrapper_class="w-40"
          />
        </.form>
        <.dropdown
          :if={Policy.can?(@current_scope, :export_analytics, @document)}
          id="analytics-export"
          class="ms-auto"
        >
          <:trigger>
            <.button variant="secondary" icon="hero-arrow-down-tray-mini">{gettext("Export")}</.button>
          </:trigger>
          <:item label>{gettext("CSV, with the filters above")}</:item>
          <:item
            icon="hero-table-cells-mini"
            href={~p"/documents/#{@document}/analytics/export/visits?#{@params}"}
          >
            {gettext("Visits")}
          </:item>
          <:item
            icon="hero-document-text-mini"
            href={~p"/documents/#{@document}/analytics/export/pages?#{@params}"}
          >
            {gettext("Time per page")}
          </:item>
        </.dropdown>
      </div>

      <section id="reading-now" class="mb-6 rounded-xl border border-border bg-surface p-4 shadow-xs">
        <div class="mb-3 flex items-center gap-2">
          <.badge tone={if(@readers == [], do: "neutral", else: "success")} pulse={@readers != []}>
            {gettext("Reading now")}
          </.badge>
          <span class="text-sm text-fg-muted tabular-nums">{length(@readers)}</span>
        </div>
        <p :if={@readers == []} class="text-sm text-fg-subtle">
          {gettext("No one is reading right now. New readers appear here instantly.")}
        </p>
        <ul class="grid gap-2 sm:grid-cols-2 xl:grid-cols-3">
          <li
            :for={r <- @readers}
            id={"reader-#{r.visit_id}"}
            class="ui-enter flex items-center gap-3 rounded-lg border border-border bg-canvas px-3 py-2.5"
          >
            <.avatar
              name={reader_name(r, @locale)}
              color={if(r.email, do: "teal", else: "slate")}
              size="md"
            />
            <div class="min-w-0 flex-1">
              <p class="truncate text-sm font-medium text-fg">{reader_name(r, @locale)}</p>
              <p class="truncate text-xs text-fg-subtle">{r.link_name}</p>
              <div class="mt-1.5 flex items-center gap-2">
                <.progress value={r.page || 0} max={r.page_count} class="flex-1" />
                <span class="text-xs text-fg-muted tabular-nums">
                  {if r.page,
                    do: gettext("p. %{page}/%{count}", page: r.page, count: r.page_count),
                    else: "–"}
                </span>
              </div>
            </div>
          </li>
        </ul>
      </section>

      <div class="mb-6 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <.stat_tile
          id="stat-visits"
          label={gettext("Visits")}
          value={Format.number(@overview.visits)}
          delta={@overview.deltas[:visits]}
          delta_label={@delta_label}
          icon="hero-eye"
        >
          <:chart><.sparkline id="spark-visits" values={@overview.series} /></:chart>
        </.stat_tile>
        <.stat_tile
          id="stat-unique"
          label={gettext("Unique viewers")}
          value={Format.number(@overview.unique)}
          delta={@overview.deltas[:unique]}
          delta_label={@delta_label}
          icon="hero-users"
        />
        <.stat_tile
          id="stat-time"
          label={gettext("Average time")}
          value={Format.duration(div(@overview.avg_ms, 1000))}
          delta={@overview.deltas[:avg_ms]}
          delta_label={@delta_label}
          icon="hero-clock"
        />
        <.stat_tile
          id="stat-completion"
          label={gettext("Completion")}
          value={Format.percent(@overview.completion)}
          hint={gettext("read to the last page")}
          icon="hero-check-badge"
        />
      </div>

      <div class="mb-6 grid gap-4 xl:grid-cols-3">
        <.card
          id="time-per-page"
          title={gettext("Time per page")}
          description={
            if @page_version,
              do:
                gettext(
                  "Average per visit, v%{n}. Faded pages were seen by fewer than half of readers.",
                  n: @page_version.number
                ),
              else: gettext("Shown once a version is ready.")
          }
          class="xl:col-span-2"
        >
          <%= if @pages == [] or @overview.visits == 0 do %>
            <.empty_state icon="hero-chart-bar" title={gettext("No reading data yet")}>
              {gettext("Share a link: time per page appears as people read.")}
            </.empty_state>
          <% else %>
            <.bar_chart id="pages-chart" bars={@page_bars} label={gettext("Seconds per page")} />
          <% end %>
        </.card>
        <.card id="per-link" title={gettext("By link")}>
          <.bar_list :if={@links != []} id="per-link-list" items={@link_items} />
          <p :if={@links == []} class="text-sm text-fg-subtle">{gettext("No links yet.")}</p>
        </.card>
      </div>

      <div class="grid gap-6 xl:grid-cols-2">
        <section>
          <h2 class="mb-3 text-md font-semibold text-fg">{gettext("Viewers")}</h2>
          <.table
            id="viewers"
            rows={@viewers}
            row_id={&"viewer-#{Base.url_encode64(&1.key, padding: false)}"}
            row_click={
              &JS.patch(~p"/documents/#{@document}/analytics?#{params(@params, viewer: &1.key)}")
            }
          >
            <:col :let={v} label={gettext("Viewer")}>
              <div class="flex min-w-0 items-center gap-2.5">
                <.avatar
                  name={viewer_name(v, @locale)}
                  color={if(v.email, do: "teal", else: "slate")}
                  size="sm"
                />
                <div class="min-w-0">
                  <p class="flex items-center gap-1.5 truncate font-medium text-fg">
                    {viewer_name(v, @locale)}
                    <.icon
                      :if={v.verified}
                      name="hero-check-badge-mini"
                      class="size-4 text-success"
                      title={gettext("Verified email")}
                    />
                  </p>
                  <p :if={v.email && location(v, @locale)} class="truncate text-xs text-fg-subtle">
                    {location(v, @locale)}
                  </p>
                </div>
              </div>
            </:col>
            <:col :let={v} label={gettext("Visits")} numeric>{v.visits}</:col>
            <:col :let={v} label={gettext("Time")} numeric>
              {Format.duration(div(v.total_ms, 1000))}
            </:col>
            <:col :let={v} label={gettext("Read")} numeric>
              {Format.percent(v.best_completion || 0)}
            </:col>
            <:col :let={v} label={gettext("Last seen")} class="text-fg-muted">
              <.relative_time at={v.last_seen} scope={@current_scope} />
            </:col>
            <:empty>
              <.empty_state icon="hero-users" title={gettext("No viewers yet")} />
            </:empty>
          </.table>
        </section>

        <section>
          <h2 class="mb-3 text-md font-semibold text-fg">{gettext("Recent visits")}</h2>
          <.visits_table
            id="visits"
            visits={@streams.visits}
            document={@document}
            params={@params}
            scope={@current_scope}
            locale={@locale}
            live_ids={@live_ids}
          />
        </section>
      </div>

      <.sheet
        :if={@viewer}
        id="viewer-sheet"
        show
        title={viewer_name(@viewer, @locale)}
        description={location(@viewer, @locale)}
        on_close={JS.patch(~p"/documents/#{@document}/analytics?#{Map.delete(@params, "viewer")}")}
      >
        <.visits_table
          id="viewer-visits"
          visits={@streams.viewer_visits}
          document={@document}
          params={@params}
          scope={@current_scope}
          locale={@locale}
          live_ids={@live_ids}
        />
      </.sheet>

      <.sheet
        :if={@visit}
        id="visit-sheet"
        show
        width="32rem"
        title={gettext("Visit")}
        description={visit_summary(@visit, @current_scope, @locale)}
        on_close={JS.patch(~p"/documents/#{@document}/analytics?#{Map.delete(@params, "visit")}")}
      >
        <.list class="mb-6">
          <:item title={gettext("Viewer")}>
            {viewer_name(@visit, @locale)}
            <.badge :if={@visit.email_verified} tone="success">{gettext("Verified")}</.badge>
          </:item>
          <:item title={gettext("Link")}>{@visit.link && @visit.link.name}</:item>
          <:item title={gettext("Location")}>{location(@visit, @locale) || "–"}</:item>
          <:item title={gettext("IP")}>
            <span class="font-mono text-xs">{@visit.ip || "–"}</span>
          </:item>
          <:item title={gettext("Time")}>{Format.duration(div(@visit.duration_ms, 1000))}</:item>
          <:item title={gettext("Pages")}>
            {gettext("%{seen} of %{count}",
              seen: @visit.pages_viewed,
              count: @visit.page_count || "?"
            )}
          </:item>
        </.list>
        <h3 class="mb-2 text-xs font-medium text-fg-subtle">
          {gettext("Page by page, in reading order")}
        </h3>
        <p :if={@visit.page_views == []} class="text-sm text-fg-subtle">
          {gettext("No pages recorded.")}
        </p>
        <ol id="visit-timeline" class="space-y-1.5">
          <li
            :for={pv <- @visit.page_views}
            id={"pv-#{pv.page}"}
            class="flex items-center gap-3 text-sm"
          >
            <span class="w-14 shrink-0 text-fg-muted tabular-nums">{gettext("p. %{n}", n: pv.page)}</span>
            <div class="h-2 flex-1 overflow-hidden rounded-full bg-hover">
              <div
                class="h-full rounded-full bg-accent/80"
                style={"width: #{bar_pct(pv.duration_ms, @visit_max_ms)}%"}
              />
            </div>
            <span class="w-16 shrink-0 text-right text-fg tabular-nums">{Format.duration(
              div(pv.duration_ms, 1000)
            )}</span>
          </li>
        </ol>
      </.sheet>
      <.geoip_credit />
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :visits, :any, required: true
  attr :document, :any, required: true
  attr :params, :map, required: true
  attr :scope, :any, required: true
  attr :locale, :string, required: true
  attr :live_ids, :any, required: true

  defp visits_table(assigns) do
    ~H"""
    <.table
      id={@id}
      rows={@visits}
      row_click={
        fn {_dom, v} ->
          JS.patch(~p"/documents/#{@document}/analytics?#{params(@params, visit: v.id)}")
        end
      }
    >
      <:col :let={{_id, v}} label={gettext("Viewer")}>
        <span class="flex min-w-0 items-center gap-2">
          <span class="truncate text-fg">{viewer_name(v, @locale)}</span>
          <.badge :if={MapSet.member?(@live_ids, v.id)} tone="success" pulse>
            {gettext("Live")}
          </.badge>
        </span>
      </:col>
      <:col :let={{_id, v}} label={gettext("Link")} class="text-fg-muted">
        {v.link && v.link.name}
      </:col>
      <:col :let={{_id, v}} label={gettext("Time")} numeric>
        {Format.duration(div(v.duration_ms, 1000))}
      </:col>
      <:col :let={{_id, v}} label={gettext("Pages")} numeric>
        {v.pages_viewed}/{v.page_count || "?"}
      </:col>
      <:col :let={{_id, v}} label={gettext("When")} class="text-fg-muted">
        <.relative_time at={v.started_at} scope={@scope} />
      </:col>
      <:empty>
        <.empty_state icon="hero-eye" title={gettext("No visits yet")} />
      </:empty>
    </.table>
    """
  end

  ## Mount and params

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Documents.get_document(scope, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That document doesn't exist or you can't see it."))
         |> push_navigate(to: ~p"/documents")}

      document ->
        if connected?(socket) do
          Analytics.subscribe_document(scope, document)
          Phoenix.PubSub.subscribe(Readout.PubSub, Presence.document_topic(document.id))
        end

        {:ok,
         socket
         |> assign(:document, document)
         |> assign(:page_title, gettext("Analytics · %{title}", title: document.title))
         |> assign(refresh_timer: nil, viewer: nil, visit: nil, visit_max_ms: 1)
         |> stream_configure(:visits, dom_id: &"visits-#{&1.id}")
         |> stream_configure(:viewer_visits, dom_id: &"viewer-visits-#{&1.id}")
         |> load_readers()}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params =
      %{"range" => "30d", "version" => ""}
      |> Map.merge(Map.take(params, ["range", "version", "viewer", "visit"]))
      |> Map.update!("range", &if(&1 in ["7d", "30d", "all"], do: &1, else: "30d"))

    {:noreply,
     socket
     |> assign(:params, params)
     |> load_all()
     |> load_viewer()
     |> load_visit()}
  end

  defp opts(socket) do
    %{"range" => range, "version" => version} = socket.assigns.params

    [
      range: range,
      version_id: if(version == "", do: nil, else: version),
      timezone: socket.assigns.current_scope.timezone
    ]
  end

  defp load_all(socket) do
    %{current_scope: scope, document: doc} = socket.assigns
    opts = opts(socket)
    page_version = page_version(doc, opts[:version_id])

    pages = if page_version, do: Analytics.time_per_page(scope, doc, page_version, opts), else: []
    links = Analytics.per_link(scope, doc, opts)

    socket
    |> assign(:overview, Analytics.overview(scope, doc, opts))
    |> assign(:delta_label, delta_label(socket.assigns.params["range"]))
    |> assign(:page_version, page_version)
    |> assign(:pages, pages)
    |> assign(:page_bars, page_bars(pages, page_version))
    |> assign(:links, links)
    |> assign(
      :link_items,
      for(
        l <- links,
        do: %{
          label: l.name,
          value: l.visits,
          display: ngettext("%{count} visit", "%{count} visits", l.visits)
        }
      )
    )
    |> assign(:viewers, Analytics.viewers(scope, doc, opts))
    |> stream(:visits, Analytics.recent_visits(scope, doc, Keyword.put(opts, :limit, 20)),
      reset: true,
      limit: 20
    )
  end

  defp page_version(doc, nil), do: doc.current_version
  defp page_version(doc, id), do: Documents.get_version(doc, id) || doc.current_version

  # For spreadsheets each "page" is a sheet: label bars with sheet names.
  defp page_bars(pages, version) do
    names =
      case version do
        %{metadata: %{"sheets" => sheets}} -> Enum.map(sheets, & &1["name"])
        _ -> []
      end

    for p <- pages do
      %{
        label: Integer.to_string(p.page),
        value: div(p.avg_ms, 100),
        display:
          "#{Format.duration(div(p.avg_ms, 1000))} · #{Format.percent(p.reach)} #{gettext("reached")}",
        hint: Enum.at(names, p.page - 1) || gettext("Page %{number}", number: p.page),
        tone: if(p.reach < 50, do: "muted")
      }
    end
  end

  defp load_viewer(%{assigns: %{params: %{"viewer" => key}}} = socket) when is_binary(key) do
    %{current_scope: scope, document: doc} = socket.assigns

    viewer =
      Enum.find(socket.assigns.viewers, &(&1.key == key)) ||
        %{key: key, email: nil, ip: nil, country: %{}, city: %{}}

    socket
    |> assign(:viewer, viewer)
    |> stream(
      :viewer_visits,
      Analytics.recent_visits(scope, doc, Keyword.put(opts(socket), :viewer, key)),
      reset: true
    )
  end

  defp load_viewer(socket),
    do: socket |> assign(:viewer, nil) |> stream(:viewer_visits, [], reset: true)

  defp load_visit(%{assigns: %{params: %{"visit" => id}}} = socket) when is_binary(id) do
    case Analytics.get_visit(socket.assigns.current_scope, id) do
      %{document_id: doc_id} = visit when doc_id == socket.assigns.document.id ->
        max_ms = visit.page_views |> Enum.map(& &1.duration_ms) |> Enum.max(fn -> 1 end) |> max(1)
        assign(socket, visit: visit, visit_max_ms: max_ms)

      _ ->
        assign(socket, :visit, nil)
    end
  end

  defp load_visit(socket), do: assign(socket, :visit, nil)

  defp load_readers(socket) do
    readers =
      socket.assigns.document.id
      |> Presence.readers()
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})

    assign(socket, readers: readers, live_ids: MapSet.new(readers, & &1.visit_id))
  end

  ## Live updates

  @impl true
  def handle_event("version", %{"version" => version}, socket) do
    params = socket.assigns.params |> Map.put("version", version) |> Map.drop(["viewer", "visit"])

    {:noreply,
     push_patch(socket, to: ~p"/documents/#{socket.assigns.document}/analytics?#{clean(params)}")}
  end

  @impl true
  def handle_info({:analytics, event, %{visit_id: id}}, socket) do
    socket =
      case event do
        :visit_started ->
          case Analytics.get_visit(socket.assigns.current_scope, id) do
            nil -> socket
            visit -> stream_insert(socket, :visits, visit, at: 0, limit: 20)
          end

        _ ->
          case Analytics.get_visit(socket.assigns.current_scope, id) do
            nil -> socket
            visit -> socket |> stream_insert(:visits, visit) |> maybe_refresh_visit(visit)
          end
      end

    {:noreply, schedule_refresh(socket)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, load_readers(socket)}
  end

  def handle_info(:refresh, socket) do
    {:noreply, socket |> assign(:refresh_timer, nil) |> refresh_stats()}
  end

  # Stats re-run at most once every 2 seconds, however busy the document is.
  defp schedule_refresh(%{assigns: %{refresh_timer: nil}} = socket),
    do: assign(socket, :refresh_timer, Process.send_after(self(), :refresh, 2000))

  defp schedule_refresh(socket), do: socket

  defp refresh_stats(socket) do
    %{current_scope: scope, document: doc} = socket.assigns
    opts = opts(socket)

    pages =
      if socket.assigns.page_version,
        do: Analytics.time_per_page(scope, doc, socket.assigns.page_version, opts),
        else: []

    links = Analytics.per_link(scope, doc, opts)

    socket
    |> assign(:overview, Analytics.overview(scope, doc, opts))
    |> assign(:pages, pages)
    |> assign(:page_bars, page_bars(pages, socket.assigns.page_version))
    |> assign(:links, links)
    |> assign(
      :link_items,
      for(
        l <- links,
        do: %{
          label: l.name,
          value: l.visits,
          display: ngettext("%{count} visit", "%{count} visits", l.visits)
        }
      )
    )
    |> assign(:viewers, Analytics.viewers(scope, doc, opts))
  end

  defp maybe_refresh_visit(%{assigns: %{visit: %{id: id}}} = socket, %{id: id}),
    do: load_visit(socket)

  defp maybe_refresh_visit(socket, _visit), do: socket

  ## Labels

  defp ranges,
    do: [{"7d", gettext("7 days")}, {"30d", gettext("30 days")}, {"all", gettext("All time")}]

  defp delta_label("7d"), do: gettext("vs previous 7 days")
  defp delta_label("30d"), do: gettext("vs previous 30 days")
  defp delta_label(_), do: nil

  defp params(params, changes) do
    changes = Map.new(changes, fn {k, v} -> {to_string(k), v} end)
    params |> Map.merge(changes) |> clean()
  end

  defp clean(params) do
    params
    |> Enum.reject(fn {k, v} -> v in [nil, ""] or {k, v} == {"range", "30d"} end)
    |> Map.new()
  end

  defp location(%{} = v, locale) do
    GeoIP.label(%{country: Map.get(v, :country) || %{}, city: Map.get(v, :city) || %{}}, locale)
  end

  defp reader_name(%{email: email}, _locale) when is_binary(email), do: email
  defp reader_name(r, locale), do: anonymous(location(r, locale))

  defp viewer_name(%{email: email}, _locale) when is_binary(email), do: email
  defp viewer_name(v, locale), do: anonymous(location(v, locale) || Map.get(v, :ip))

  defp anonymous(nil), do: gettext("Anonymous")
  defp anonymous(place), do: gettext("Anonymous · %{place}", place: place)

  defp visit_summary(visit, scope, _locale), do: Format.datetime(visit.started_at, scope)

  defp bar_pct(_ms, 0), do: 0
  defp bar_pct(ms, max), do: Float.round(ms / max * 100, 1)
end
