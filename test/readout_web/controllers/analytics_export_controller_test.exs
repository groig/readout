defmodule ReadoutWeb.AnalyticsExportControllerTest do
  use ReadoutWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.{Analytics, Links}

  setup :register_and_log_in_user

  setup %{scope: scope} do
    {doc, link} = shared_fixture(scope)
    {:ok, link} = Links.fetch_public_link(link.slug)

    visit = Links.start_visit(link, %{email: "=cmd@evil.com", device_id: "dev-1"})
    _ = Analytics.record(visit, %{1 => 12_000, 2 => 3_500}, %{1 => 1, 2 => 2}, 2)

    %{doc: doc, visit: visit}
  end

  defp csv(conn),
    do: conn |> response(200) |> String.trim_leading("﻿") |> String.split("\r\n", trim: true)

  test "exports visits as CSV", %{conn: conn, doc: doc, visit: visit} do
    conn = get(conn, ~p"/documents/#{doc}/analytics/export/visits?range=all")
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/csv"
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "visits"

    [header, row] = csv(conn)
    assert header =~ "Started"
    assert row =~ visit.id
    # Formula-looking values are defused.
    assert row =~ "'=cmd@evil.com"
    assert row =~ "15.5"
    assert row =~ "Client X"
  end

  test "exports time per page", %{conn: conn, doc: doc, visit: visit} do
    [_header | rows] = csv(get(conn, ~p"/documents/#{doc}/analytics/export/pages"))
    assert length(rows) == 2
    assert Enum.all?(rows, &(&1 =~ visit.id))
    assert Enum.at(rows, 0) =~ ",1,,12.0,1,"
    assert Enum.at(rows, 1) =~ ",2,,3.5,2,"
  end

  test "is logged in the audit log", %{conn: conn, doc: doc} do
    get(conn, ~p"/documents/#{doc}/analytics/export/visits")

    assert [%{action: "analytics.exported"}] =
             Readout.Repo.all(Readout.Audit.Event)
             |> Enum.filter(&(&1.action == "analytics.exported"))
  end

  test "observers and outsiders can't export", %{doc: doc} do
    observer = user_fixture(%{role: :observer})
    conn = build_conn() |> log_in_user(observer)
    assert response(get(conn, ~p"/documents/#{doc}/analytics/export/visits"), 404)

    assert response(
             get(
               build_conn() |> log_in_user(observer),
               ~p"/documents/#{doc}/analytics/export/nope"
             ),
             404
           )
  end

  test "the analytics page offers the export to people allowed", %{conn: conn, doc: doc} do
    {:ok, lv, _} = live(conn, ~p"/documents/#{doc}/analytics?range=7d")
    assert has_element?(lv, "#analytics-export a[href*='/analytics/export/visits?range=7d']")

    observer = user_fixture(%{role: :observer})
    {:ok, lv, _} = live(build_conn() |> log_in_user(observer), ~p"/documents/#{doc}/analytics")
    refute has_element?(lv, "#analytics-export")
  end
end
