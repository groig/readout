defmodule Readout.Analytics do
  @moduledoc """
  Reading analytics: recording what `Readout.Analytics.Tracker` measures, and
  the queries behind the document dashboard and the workspace overview.

  Everything is read through `Readout.Policy` (`:view_document`); live events
  carry ids only, so subscribers re-read through their own scope.
  """

  import Ecto.Query, warn: false

  alias Readout.Accounts.Scope
  alias Readout.Analytics.PageView
  alias Readout.Documents.{Document, Version}
  alias Readout.Links.{Link, Visit}
  alias Readout.{Documents, Policy, Repo}

  @topic "analytics"

  ## Live events

  def subscribe(%Scope{}), do: Phoenix.PubSub.subscribe(Readout.PubSub, @topic)

  def subscribe_document(%Scope{} = scope, %Document{} = doc) do
    if Policy.can?(scope, :view_document, doc),
      do: Phoenix.PubSub.subscribe(Readout.PubSub, "#{@topic}:#{doc.id}")
  end

  @doc false
  def broadcast(event, %Visit{id: id, document_id: doc_id}) do
    message = {:analytics, event, %{visit_id: id, document_id: doc_id}}
    Phoenix.PubSub.broadcast(Readout.PubSub, @topic, message)
    Phoenix.PubSub.broadcast(Readout.PubSub, "#{@topic}:#{doc_id}", message)
  end

  ## Recording

  @doc """
  Adds measured time (`%{page => ms}`) and page arrivals (`%{page => n}`) to a
  visit, and updates its totals.
  """
  def record(%Visit{} = visit, ms_by_page, views_by_page, last_page \\ nil) do
    pages = Map.keys(ms_by_page) ++ Map.keys(views_by_page)

    if pages == [] do
      visit
    else
      now = DateTime.utc_now()

      rows =
        for page <- Enum.uniq(pages) do
          %{
            id: Ecto.UUID.generate(),
            visit_id: visit.id,
            document_id: visit.document_id,
            version_id: visit.version_id,
            page: page,
            duration_ms: Map.get(ms_by_page, page, 0),
            views: Map.get(views_by_page, page, 0),
            first_seen_at: now,
            last_seen_at: now
          }
        end

      Repo.insert_all(PageView, rows,
        on_conflict:
          from(p in PageView,
            update: [
              inc: [
                duration_ms: fragment("EXCLUDED.duration_ms"),
                views: fragment("EXCLUDED.views")
              ],
              set: [last_seen_at: fragment("EXCLUDED.last_seen_at")]
            ]
          ),
        conflict_target: [:visit_id, :page]
      )

      added = ms_by_page |> Map.values() |> Enum.sum()

      {1, [visit]} =
        from(v in Visit,
          where: v.id == ^visit.id,
          select: v,
          update: [
            inc: [duration_ms: ^added],
            set: [
              last_seen_at: ^now,
              pages_viewed:
                fragment("(SELECT count(*) FROM page_views WHERE visit_id = ?)", v.id),
              last_page: coalesce(type(^last_page, :integer), v.last_page)
            ]
          ]
        )
        |> Repo.update_all([])

      broadcast(:visit_updated, visit)
      visit
    end
  end

  ## Document dashboard

  @doc """
  Options for every document query:

    * `:range` - `"7d"`, `"30d"` or `"all"` (default `"30d"`)
    * `:version_id` - one version, or nil for all
    * `:timezone` - for daily buckets (default UTC)
  """
  def overview(%Scope{} = scope, %Document{} = doc, opts \\ []) do
    authorize!(scope, doc)
    {from, previous_from} = range_bounds(opts[:range])

    current = totals(visits(doc, opts) |> since(from))

    previous =
      if previous_from,
        do: totals(visits(doc, opts) |> since(previous_from) |> where([v], v.started_at < ^from)),
        else: nil

    Map.merge(current, %{
      series: daily_series(doc, opts, from),
      deltas: deltas(current, previous)
    })
  end

  defp totals(query) do
    from(v in query,
      select: %{
        visits: count(v.id),
        unique: count(fragment("DISTINCT coalesce(?::text, ?, ?)", v.email, v.device_id, v.ip)),
        total_ms: coalesce(sum(v.duration_ms), 0),
        completed: filter(count(v.id), v.pages_viewed >= v.page_count and v.page_count > 0)
      }
    )
    |> Repo.one()
    |> then(fn t ->
      t
      |> Map.put(:avg_ms, if(t.visits > 0, do: div(to_int(t.total_ms), t.visits), else: 0))
      |> Map.put(:completion, if(t.visits > 0, do: t.completed / t.visits * 100, else: 0.0))
    end)
  end

  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n), do: n

  defp deltas(_current, nil), do: %{}

  defp deltas(current, previous) do
    pct = fn
      _now, 0 -> nil
      now, before -> (now - before) / before * 100
    end

    %{
      visits: pct.(current.visits, previous.visits),
      unique: pct.(current.unique, previous.unique),
      avg_ms: pct.(current.avg_ms, previous.avg_ms),
      completion: if(previous.visits > 0, do: current.completion - previous.completion, else: nil)
    }
  end

  defp daily_series(doc, opts, from) do
    tz = opts[:timezone] || "Etc/UTC"
    days = if from, do: max(Date.diff(Date.utc_today(), DateTime.to_date(from)), 1), else: 30
    first_day = Date.add(Date.utc_today(), -days + 1)

    counts =
      from(v in visits(doc, opts),
        where: v.started_at >= ^DateTime.new!(first_day, ~T[00:00:00], "Etc/UTC"),
        group_by: selected_as(:day),
        select:
          {selected_as(
             fragment("date(? AT TIME ZONE 'UTC' AT TIME ZONE ?)", v.started_at, ^tz),
             :day
           ), count(v.id)}
      )
      |> Repo.all()
      |> Map.new()

    for d <- 0..(days - 1), do: Map.get(counts, Date.add(first_day, d), 0)
  end

  @doc """
  For each page of a version: average seconds per visit and reach (the share
  of visits that saw it). Where reach drops, readers stopped.
  """
  def time_per_page(%Scope{} = scope, %Document{} = doc, %Version{} = version, opts \\ []) do
    authorize!(scope, doc)
    {from, _} = range_bounds(opts[:range])
    visit_query = visits(doc, Keyword.put(opts, :version_id, version.id)) |> since(from)
    total = Repo.aggregate(visit_query, :count)

    by_page =
      from(p in PageView,
        join: v in subquery(visit_query),
        on: v.id == p.visit_id,
        group_by: p.page,
        select: {p.page, %{ms: sum(p.duration_ms), visits: count(p.visit_id)}}
      )
      |> Repo.all()
      |> Map.new()

    for page <- 1..max(version.page_count || 1, 1) do
      stats = Map.get(by_page, page, %{ms: 0, visits: 0})

      %{
        page: page,
        avg_ms: if(total > 0, do: div(to_int(stats.ms), total), else: 0),
        reach: if(total > 0, do: stats.visits / total * 100, else: 0.0)
      }
    end
  end

  @doc "Visits, unique viewers and average time per link (including room links)."
  def per_link(%Scope{} = scope, %Document{} = doc, opts \\ []) do
    authorize!(scope, doc)
    {from, _} = range_bounds(opts[:range])

    from(l in Link,
      left_join: v in subquery(visits(doc, opts) |> since(from)),
      on: v.link_id == l.id,
      # Its own links (even unvisited), plus room links it was read through.
      where: l.document_id == ^doc.id or not is_nil(v.id),
      group_by: [l.id, l.name],
      order_by: [desc: count(v.id), asc: l.name],
      select: %{
        link_id: l.id,
        name: l.name,
        visits: count(v.id),
        unique: count(fragment("DISTINCT coalesce(?::text, ?, ?)", v.email, v.device_id, v.ip)),
        avg_ms: coalesce(avg(v.duration_ms), 0)
      }
    )
    |> Repo.all()
    |> Enum.map(&%{&1 | avg_ms: &1.avg_ms |> to_float() |> round()})
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n), do: n * 1.0

  @doc """
  People who read the document: by email, or anonymous by device (a cookie
  per link; by IP when cookies were blocked), with their location. Most
  recent first.
  """
  def viewers(%Scope{} = scope, %Document{} = doc, opts \\ []) do
    authorize!(scope, doc)
    {from, _} = range_bounds(opts[:range])

    from(v in (visits(doc, opts) |> since(from)),
      group_by:
        fragment("coalesce(?::text, 'dev:' || ?, 'ip:' || ?)", v.email, v.device_id, v.ip),
      order_by: [desc: max(v.started_at)],
      limit: 200,
      select: %{
        key: fragment("coalesce(?::text, 'dev:' || ?, 'ip:' || ?)", v.email, v.device_id, v.ip),
        email: max(v.email),
        verified: fragment("bool_or(?)", v.email_verified),
        ip: max(v.ip),
        country: fragment("(array_agg(? ORDER BY ? DESC))[1]", v.country, v.started_at),
        city: fragment("(array_agg(? ORDER BY ? DESC))[1]", v.city, v.started_at),
        visits: count(v.id),
        total_ms: sum(v.duration_ms),
        last_seen: max(v.last_seen_at),
        best_completion:
          max(
            fragment(
              "CASE WHEN ? > 0 THEN ?::float / ? * 100 ELSE 0 END",
              v.page_count,
              v.pages_viewed,
              v.page_count
            )
          )
      }
    )
    |> Repo.all()
    |> Enum.map(&Map.update!(&1, :total_ms, fn ms -> to_int(ms || 0) end))
  end

  @doc "The latest visits of a document (or of one viewer), with their link."
  def recent_visits(%Scope{} = scope, %Document{} = doc, opts \\ []) do
    authorize!(scope, doc)
    {from, _} = range_bounds(opts[:range])

    visits(doc, opts)
    |> since(from)
    |> viewer_filter(opts[:viewer])
    |> order_by(desc: :started_at)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> preload(:link)
    |> Repo.all()
  end

  defp viewer_filter(query, nil), do: query

  defp viewer_filter(query, "dev:" <> id),
    do: where(query, [v], is_nil(v.email) and v.device_id == ^id)

  defp viewer_filter(query, "ip:" <> ip),
    do: where(query, [v], is_nil(v.email) and is_nil(v.device_id) and v.ip == ^ip)

  defp viewer_filter(query, email), do: where(query, [v], v.email == ^email)

  @doc "One visit with its pages in the order they were first seen."
  def get_visit(%Scope{} = scope, id) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         %Visit{} = visit <- Repo.get(Visit, id) |> Repo.preload([:link, :page_views]),
         %Document{} = doc <- Documents.get_document(scope, visit.document_id) do
      %{visit | document: doc}
    else
      _ -> nil
    end
  end

  ## Rooms

  @doc """
  A room's roll-up: totals over visits through its links, visits and time per
  document (in room order), and the latest visits.
  """
  def room_overview(%Scope{} = scope, %Readout.Rooms.Room{} = room, opts \\ []) do
    unless Policy.can?(scope, :view_room, room), do: raise(ArgumentError, "unauthorized")
    {from, _} = range_bounds(opts[:range])

    base =
      from(v in Visit, join: l in Link, on: l.id == v.link_id, where: l.room_id == ^room.id)
      |> since(from)

    per_doc =
      from(v in base,
        group_by: v.document_id,
        select: {v.document_id, %{visits: count(v.id), total_ms: sum(v.duration_ms)}}
      )
      |> Repo.all()
      |> Map.new()

    %{
      totals: totals(base),
      per_document:
        for doc <- room.documents do
          stats = Map.get(per_doc, doc.id, %{visits: 0, total_ms: 0})
          total = to_int(stats.total_ms || 0)

          %{
            document_id: doc.id,
            title: doc.title,
            visits: stats.visits,
            avg_ms: if(stats.visits > 0, do: div(total, stats.visits), else: 0)
          }
        end,
      recent:
        from(v in base, order_by: [desc: v.started_at], limit: 30, preload: [:link, :document])
        |> Repo.all()
    }
  end

  ## Workspace overview

  @doc "Totals, top documents and recent visits across the documents the scope can see."
  def workspace_overview(%Scope{} = scope, opts \\ []) do
    docs = Documents.list_documents(scope)
    ids = Enum.map(docs, & &1.id)
    {from, previous_from} = range_bounds(opts[:range] || "7d")

    base = from(v in Visit, where: v.document_id in ^ids)
    current = totals(since(base, from))

    previous =
      previous_from && totals(base |> since(previous_from) |> where([v], v.started_at < ^from))

    top =
      from(v in since(base, from),
        group_by: v.document_id,
        order_by: [desc: count(v.id)],
        limit: 8,
        select: {v.document_id, count(v.id), sum(v.duration_ms)}
      )
      |> Repo.all()

    titles = Map.new(docs, &{&1.id, &1.title})

    %{
      totals: current,
      deltas: deltas(current, previous),
      top_documents:
        for(
          {id, n, ms} <- top,
          do: %{document_id: id, title: titles[id], visits: n, total_ms: to_int(ms || 0)}
        ),
      document_ids: MapSet.new(ids)
    }
  end

  @doc "Recent visits across visible documents (the activity feed)."
  def recent_activity(%Scope{} = scope, document_ids, opts \\ []) do
    ids = MapSet.to_list(document_ids)
    _ = scope

    from(v in Visit,
      where: v.document_id in ^ids,
      order_by: [desc: v.started_at],
      limit: ^Keyword.get(opts, :limit, 40),
      preload: [:link, :document]
    )
    |> Repo.all()
  end

  @doc "A single visit for the feed, if its document is visible."
  def feed_visit(document_ids, visit_id) do
    case Repo.get(Visit, visit_id) do
      %Visit{document_id: doc_id} = v ->
        if MapSet.member?(document_ids, doc_id), do: Repo.preload(v, [:link, :document])

      nil ->
        nil
    end
  end

  ## Helpers

  defp authorize!(scope, doc) do
    unless Policy.can?(scope, :view_document, doc), do: raise(ArgumentError, "unauthorized")
  end

  defp visits(%Document{id: id}, opts) do
    query = from(v in Visit, where: v.document_id == ^id)

    case opts[:version_id] do
      nil -> query
      version_id -> where(query, [v], v.version_id == ^version_id)
    end
  end

  defp since(query, nil), do: query
  defp since(query, from), do: where(query, [v], v.started_at >= ^from)

  @doc false
  def range_bounds(range) do
    now = DateTime.utc_now()

    case range do
      "7d" -> {DateTime.add(now, -7, :day), DateTime.add(now, -14, :day)}
      "all" -> {nil, nil}
      _ -> {DateTime.add(now, -30, :day), DateTime.add(now, -60, :day)}
    end
  end
end
