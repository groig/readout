defmodule ReadoutWeb.AnalyticsExportController do
  @moduledoc """
  A document's analytics as CSV, with the dashboard's filters (`range`,
  `version`): `visits` (one row per visit) or `pages` (one row per page read
  in each visit). Times are in the person's time zone, durations in seconds,
  locations in their language. Needs `:export_analytics`; every export is in
  the audit log, since the files hold viewers' emails and IP addresses.
  """
  use ReadoutWeb, :controller

  alias Readout.{Analytics, Audit, Documents, GeoIP, Policy}
  alias Readout.Documents.{Sheets, Version}

  def show(conn, %{"id" => id, "kind" => kind} = params) when kind in ["visits", "pages"] do
    scope = conn.assigns.current_scope

    with %{} = doc <- Documents.get_document(scope, id),
         :ok <- Policy.authorize(scope, :export_analytics, doc) do
      opts = [range: params["range"], version_id: version_id(doc, params["version"])]
      visits = Analytics.export_visits(scope, doc, opts)

      Audit.log(scope, "analytics.exported", doc, %{
        kind: kind,
        range: params["range"] || "30d",
        rows: length(visits)
      })

      filename = "#{doc.title} – #{kind_label(kind)} #{Date.utc_today()}.csv"

      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header(
        "content-disposition",
        ReadoutWeb.DocumentFileController.content_disposition(filename)
      )
      |> send_resp(200, Readout.CSV.encode(rows(kind, visits, scope)))
    else
      _ -> conn |> put_resp_content_type("text/plain") |> send_resp(404, "Not found")
    end
  end

  def show(conn, _params),
    do: conn |> put_resp_content_type("text/plain") |> send_resp(404, "Not found")

  defp version_id(doc, id) when is_binary(id) do
    Enum.find_value(doc.versions, fn v -> v.id == id && v.id end)
  end

  defp version_id(_doc, _), do: nil

  defp kind_label("visits"), do: gettext("visits")
  defp kind_label("pages"), do: gettext("pages")

  defp rows("visits", visits, scope) do
    header = [
      gettext("Visit"),
      gettext("Started"),
      gettext("Ended"),
      gettext("Link"),
      gettext("Email"),
      gettext("Email verified"),
      gettext("Device"),
      gettext("IP address"),
      gettext("Location"),
      gettext("Version"),
      gettext("Seconds reading"),
      gettext("Pages viewed"),
      gettext("Pages in document"),
      gettext("Completion %"),
      gettext("Last page"),
      gettext("Browser")
    ]

    [
      header
      | for v <- visits do
          [
            v.id,
            time(v.started_at, scope),
            time(v.ended_at, scope),
            v.link && v.link.name,
            v.email,
            v.email_verified,
            v.device_id,
            v.ip,
            GeoIP.label(%{country: v.country || %{}, city: v.city || %{}}, scope.locale),
            v.version && v.version.number,
            seconds(v.duration_ms),
            v.pages_viewed,
            v.page_count,
            completion(v),
            v.last_page,
            v.user_agent
          ]
        end
    ]
  end

  defp rows("pages", visits, scope) do
    header = [
      gettext("Visit"),
      gettext("Started"),
      gettext("Link"),
      gettext("Email"),
      gettext("Device"),
      gettext("Version"),
      gettext("Page"),
      gettext("Sheet"),
      gettext("Seconds"),
      gettext("Times viewed"),
      gettext("First seen")
    ]

    names = sheet_names(visits)

    [
      header
      | for v <- visits, p <- v.page_views do
          [
            v.id,
            time(v.started_at, scope),
            v.link && v.link.name,
            v.email,
            v.device_id,
            v.version && v.version.number,
            p.page,
            names[{v.version_id, p.page}],
            seconds(p.duration_ms),
            p.views,
            time(p.first_seen_at, scope)
          ]
        end
    ]
  end

  # Spreadsheet versions: sheet names, so "page 2" reads as "Q2".
  defp sheet_names(visits) do
    for %{version: %Version{} = version} <- visits,
        Version.kind(version) == :sheets,
        uniq: true do
      version
    end
    |> Enum.flat_map(fn version ->
      for n <- 1..(version.page_count || 0)//1,
          {:ok, %{"name" => name}} <- [Sheets.load(version, n)],
          do: {{version.id, n}, name}
    end)
    |> Map.new()
  end

  defp time(nil, _scope), do: nil

  defp time(dt, scope) do
    dt
    |> Readout.TimeZones.shift(scope.timezone)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp seconds(nil), do: nil
  defp seconds(ms), do: Float.round(ms / 1000, 1)

  defp completion(%{page_count: n, pages_viewed: viewed}) when is_integer(n) and n > 0,
    do: round(viewed * 100 / n)

  defp completion(_), do: nil
end
